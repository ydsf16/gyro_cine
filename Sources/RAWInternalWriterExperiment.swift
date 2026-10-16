#if DEBUG
import AVFoundation

/// Opt-in RAW, audio and metadata integration experiment. All state lives on the camera queue.
@available(iOS 27.0, *)
final class RAWInternalWriterExperiment: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let dataOutput: AVCaptureVideoDataOutput
    let audioOutput: AVCaptureAudioDataOutput
    private let queue: DispatchQueue
    private let camera: AVCaptureDevice
    private let codec: AVVideoCodecType
    private let url: URL
    private let log: (String, [String: Any]) -> Void
    private let started: (CMTime) -> Void
    private let orientation: RecordingOrientation
    private let imuReady: () -> Bool
    private let metadata: (CMSampleBuffer) -> Void
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var audioPending: [CMSampleBuffer] = []
    private var audioPackets = 0
    private var receivedVideo = 0
    private var receivedAudio = 0
    private var lastVideoDuration = CMTime.invalid
    private let finished: (Error?) -> Void
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var requestedWB = false
    private var readyWB = false
    private var stopping = false
    private var completed = false
    private var pending: [CMSampleBuffer] = []
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var frames = 0
    private var captureDrops = 0
    private var preparationDrops = 0
    private var peakBuffered = 0
    private var maxGap = 0.0
    private var stopDeadline = 0.0
    private let maxBuffered = 3 // Bound retained camera buffers; never grow with recording duration.

    init(camera: AVCaptureDevice, codec: AVVideoCodecType, url: URL, queue: DispatchQueue,
         preview: RAWWriterPreview,
         orientation: RecordingOrientation, imuReady: @escaping () -> Bool,
         metadata: @escaping (CMSampleBuffer) -> Void,
         log: @escaping (String, [String: Any]) -> Void, started: @escaping (CMTime) -> Void,
         finished: @escaping (Error?) -> Void) {
        self.camera = camera; self.codec = codec; self.url = url; self.queue = queue
        self.log = log; self.started = started; self.finished = finished
        self.orientation = orientation; self.imuReady = imuReady; self.metadata = metadata
        dataOutput = preview.dataOutput; audioOutput = preview.audioOutput
        requestedWB = preview.ready; readyWB = preview.ready
        super.init()
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
    }
    func arm() {
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.firstPTS == nil, !self.completed else { return }
            self.log("raw_writer_start_timeout", ["videoReceived": self.receivedVideo,
                "audioReceived": self.receivedAudio, "wbRequested": self.requestedWB,
                "wbReady": self.readyWB, "imuReady": self.imuReady(), "wbMode": self.camera.whiteBalanceMode.rawValue])
            self.finish(self.failure("RAW 启动未就绪：视频 \(self.receivedVideo) 帧，音频 \(self.receivedAudio) 包，白平衡 \(self.readyWB ? "已就绪" : "等待中")"))
        }
    }
    private func failure(_ message: String) -> Error {
        NSError(domain: "GyroCine.RAWWriterExperiment", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
    func stop() {
        guard !completed, !stopping else { return }
        stopping = true
        stopDeadline = ProcessInfo.processInfo.systemUptime + 5
        drain()
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if firstPTS == nil { preparationDrops += 1 } else { captureDrops += 1 }
        log("raw_writer_capture_drop", ["pts": CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds,
            "phase": firstPTS == nil ? "preparation" : "recording",
            "reason": String(describing: CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil))])
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard !stopping, !completed else { return }
        if output === audioOutput {
            receivedAudio += 1
            if receivedAudio == 1 { log("raw_writer_first_audio", ["pts": CMSampleBufferGetPresentationTimeStamp(sample).seconds]) }
            audioFormat = CMSampleBufferGetFormatDescription(sample)
            guard let firstPTS else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= firstPTS else { return }
            guard audioPending.count < 16 else { finish(failure("音频写入持续积压")); return }
            audioPending.append(sample)
            drain()
            return
        }
        receivedVideo += 1
        if receivedVideo == 1 { log("raw_writer_first_video", ["pts": CMSampleBufferGetPresentationTimeStamp(sample).seconds]) }
        if !requestedWB {
            requestedWB = true
            log("raw_writer_wb_before_request", ["mode": camera.whiteBalanceMode.rawValue,
                "adjusting": camera.isAdjustingWhiteBalance])
            do {
                try camera.lockForConfiguration()
                camera.setWhiteBalanceModeLocked(with: camera.deviceWhiteBalanceGains) { [weak self] time in
                    guard let self else { return }
                    self.queue.async { self.readyWB = true; self.log("raw_writer_wb_effective", ["pts": time.seconds]) }
                }
                camera.unlockForConfiguration()
                log("raw_writer_wb_requested", ["mode": camera.whiteBalanceMode.rawValue])
            } catch { finish(error) }
            return
        }
        guard readyWB, imuReady(), let audioFormat else { return }
        if writer == nil {
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                guard w.isProVideoStorageSupported else { throw failure("Writer 不支持专用存储") }
                w.usesProVideoStorage = true
                var settings: [String: Any]?
                if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                    settings = self.dataOutput.recommendedVideoSettings(forVideoCodecType: self.codec, assetWriterOutputFileType: .mov)
                    w.metadata = self.dataOutput.recommendedMovieMetadata(forVideoCodecType: self.codec, assetWriterOutputFileType: .mov) ?? []
                }) { throw failure(exception) }
                guard let settings, let hint = CMSampleBufferGetFormatDescription(sample) else { throw failure("缺少 RAW 编码配置") }
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
                i.expectsMediaDataInRealTime = true
                let size = CMVideoFormatDescriptionGetDimensions(hint)
                i.transform = orientation.movieTransform(width: Int(size.width), height: Int(size.height))
                guard w.canAdd(i) else { throw failure("无法添加 RAW Writer 输入") }
                w.add(i)
                guard let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(audioFormat)?.pointee else {
                    throw failure("缺少音频格式")
                }
                let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: asbd.mSampleRate, AVNumberOfChannelsKey: asbd.mChannelsPerFrame,
                    AVEncoderBitRateKey: asbd.mChannelsPerFrame == 1 ? 128_000 : 256_000]
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
                audio.expectsMediaDataInRealTime = true
                guard w.canAdd(audio) else { throw failure("无法添加音频输入") }
                w.add(audio); audioInput = audio
                guard w.startWriting() else { throw w.error ?? failure("Writer 启动失败") }
                writer = w; input = i
                log("raw_writer_encoder_ready", ["file": url.path, "codec": codec.rawValue,
                    "dedicated": w.usesProVideoStorage, "settings": settings])
                // Encoder creation can take longer than a frame. Begin the recorded interval
                // with the next delivered frame, retaining its real capture timestamp.
                return
            } catch { finish(error); return }
        }
        if firstPTS == nil, let writer {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            writer.startSession(atSourceTime: pts)
            firstPTS = pts
            log("raw_writer_started", ["file": url.path, "pts": pts.seconds])
            started(pts)
        }
        guard pending.count < maxBuffered else {
            finish(failure("RAW 写入持续积压，已停止录制并保留原片")); return
        }
        metadata(sample)
        pending.append(sample)
        peakBuffered = max(peakBuffered, pending.count)
        drain()
    }
    private var retryScheduled = false
    private func drain() {
        guard !completed, let writer, let input else {
            if stopping && !completed { finish(failure("RAW 尚未开始录制")) }
            return
        }
        guard writer.status == .writing else { finish(writer.error ?? failure("Writer 意外停止")); return }
        while !pending.isEmpty && input.isReadyForMoreMediaData {
            let sample = pending.removeFirst()
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard input.append(sample) else { finish(writer.error ?? failure("RAW 帧写入失败")); return }
            if let lastPTS { maxGap = max(maxGap, CMTimeSubtract(pts, lastPTS).seconds) }
            lastPTS = pts; lastVideoDuration = CMSampleBufferGetDuration(sample); frames += 1
        }
        if let audioInput {
            while !audioPending.isEmpty && audioInput.isReadyForMoreMediaData {
                let audio = audioPending.removeFirst()
                guard audioInput.append(audio) else { finish(writer.error ?? failure("音频写入失败")); return }
                audioPackets += 1
            }
        }
        if stopping && pending.isEmpty && audioPending.isEmpty {
            if let lastPTS {
                let duration = lastVideoDuration.isNumeric && lastVideoDuration.seconds > 0 ? lastVideoDuration : camera.activeVideoMinFrameDuration
                writer.endSession(atSourceTime: CMTimeAdd(lastPTS, duration))
            }
            input.markAsFinished()
            audioInput?.markAsFinished()
            completed = true
            writer.finishWriting { self.queue.async { self.report(writer.status == .completed ? nil : writer.error ?? self.failure("RAW 保存失败")) } }
        } else if (!pending.isEmpty || !audioPending.isEmpty) && !retryScheduled {
            if stopping && ProcessInfo.processInfo.systemUptime > stopDeadline {
                finish(failure("RAW 写入队列未能排空")); return
            }
            retryScheduled = true
            queue.asyncAfter(deadline: .now() + 0.005) { [weak self] in
                guard let self else { return }; self.retryScheduled = false; self.drain()
            }
        }
    }
    private func finish(_ error: Error) {
        guard !completed else { return }
        completed = true; pending.removeAll(); audioPending.removeAll()
        if let writer, writer.status == .writing, let input {
            input.markAsFinished(); audioInput?.markAsFinished()
            writer.finishWriting { self.queue.async { self.report(error) } }
        } else { report(error) }
    }
    private func report(_ error: Error?) {
        log("raw_writer_finished", ["file": url.path, "frames": frames, "captureDrops": captureDrops,
            "audioPackets": audioPackets, "receivedVideo": receivedVideo, "receivedAudio": receivedAudio, "rotation": orientation.degrees, "preparationDrops": preparationDrops, "peakBuffered": peakBuffered, "maxGap": maxGap, "error": error.map { String(describing: $0) } ?? ""])
        finished(error)
    }
}

/// Native RAW outputs stay attached between recordings. White balance locks once
/// after entering RAW preview, with actual frame/effective-time evidence.
@available(iOS 27.0, *)
final class RAWWriterPreview: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let dataOutput = AVCaptureVideoDataOutput()
    let audioOutput = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private let camera: AVCaptureDevice
    private let log: (String, [String: Any]) -> Void
    private let completion: (Error?) -> Void
    private var requested = false
    private var valid = true
    private(set) var ready = false
    private var videoCount = 0
    private var audioCount = 0
    init(camera: AVCaptureDevice, queue: DispatchQueue, log: @escaping (String, [String: Any]) -> Void,
         completion: @escaping (Error?) -> Void) {
        self.camera = camera; self.queue = queue; self.log = log; self.completion = completion
        super.init()
        dataOutput.automaticallyConfiguresOutputBufferDimensions = false
        dataOutput.deliversPreviewSizedOutputBuffers = false
        dataOutput.alwaysDiscardsLateVideoFrames = true
        resume()
    }
    func resume() {
        dataOutput.setSampleBufferDelegate(self, queue: queue)
        audioOutput.setSampleBufferDelegate(self, queue: queue)
    }
    func invalidate() { valid = false }
    func configure() {
        dataOutput.videoSettings = [:]
        if let c = dataOutput.connection(with: .video) {
            c.videoRotationAngle = 0
            if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .off }
            if c.isCameraIntrinsicMatrixDeliverySupported { c.isCameraIntrinsicMatrixDeliveryEnabled = true }
        }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.valid, !self.ready else { return }
            self.valid = false
            self.log("raw_preview_timeout", ["video": self.videoCount, "audio": self.audioCount])
            self.completion(NSError(domain: "GyroCine.RAWPreview", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "RAW 预览白平衡尚未就绪"]))
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard valid else { return }
        if output === audioOutput { audioCount += 1; return }
        videoCount += 1
        guard !requested else { return }
        requested = true
        do {
            try camera.lockForConfiguration()
            camera.setWhiteBalanceModeLocked(with: AVCaptureDevice.currentWhiteBalanceGains) { [weak self] time in
                guard let self else { return }
                self.queue.async {
                    guard self.valid else { return }
                    self.ready = true
                    self.log("raw_preview_ready", ["effectivePTS": time.seconds, "video": self.videoCount,
                        "audio": self.audioCount, "wbMode": self.camera.whiteBalanceMode.rawValue])
                    self.completion(nil)
                }
            }
            camera.unlockForConfiguration()
            log("raw_preview_lock_requested", ["mode": camera.whiteBalanceMode.rawValue])
        } catch { valid = false; completion(error) }
    }
}
#endif
