import AVFoundation

/// Counts all samples waiting for and inside the writer, not only its pending array.
final class RAWFrameBudget {
    private let lock = NSLock()
    private let limit: Int
    private var count = 0
    private var highWater = 0
    init(limit: Int) { self.limit = limit }
    func acquire() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard count < limit else { return false }
        count += 1; highWater = max(highWater, count)
        return true
    }
    func release() { lock.lock(); count -= 1; lock.unlock() }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return highWater }
}

/// Five-second PTS windows; isolated gaps are reported, sustained >5% loss stops capture.
struct RAWCadenceGuard {
    private var start: Double?
    private var previous: Double?
    private var missing = 0
    private var intervals = 0
    mutating func observe(_ pts: Double, fps: Double) -> Int? {
        guard pts.isFinite, fps.isFinite, fps > 0 else { return nil }
        guard let last = previous, let beginning = start else {
            previous = pts; start = pts; return nil
        }
        guard pts > last else { return nil }
        missing += max(0, Int(((pts - last) * fps).rounded()) - 1)
        previous = pts
        intervals += 1
        let elapsed = pts - beginning
        guard elapsed >= 5 else { return nil }
        let lost = max(missing, Int((elapsed * fps).rounded()) - intervals)
        missing = 0; intervals = 0; start = pts
        return Double(lost) > max(3, elapsed * fps * 0.05) ? lost : nil
    }
}

private final class RAWBufferedSample {
    let sample: CMSampleBuffer
    private let budget: RAWFrameBudget
    init(_ sample: CMSampleBuffer, budget: RAWFrameBudget) { self.sample = sample; self.budget = budget }
    deinit { budget.release() }
}

/// RAW, audio and metadata recorder for dedicated storage or external SSD. Writer state lives on a dedicated serial queue, isolated from camera configuration and HUD polling.
@available(iOS 27.0, *)
final class RAWInternalWriterExperiment: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let dataOutput: AVCaptureVideoDataOutput
    let audioOutput: AVCaptureAudioDataOutput
    private let queue: DispatchQueue
    private let captureQueue = DispatchQueue(label: "GyroCine.rawIngress", qos: .userInteractive)
    private let videoBudget = RAWFrameBudget(limit: 10)
    private let audioBudget = RAWFrameBudget(limit: 32)
    private var accepting = true // captureQueue only
    private var ingressArmed = false
    private var preparingVideo = false
    private let camera: AVCaptureDevice
    private let codec: AVVideoCodecType
    private let url: URL
    private let dedicatedStorage: Bool
    private let log: (String, [String: Any]) -> Void
    private let prepareRecovery: () throws -> Void
    private let started: (CMTime) -> Void
    private let orientation: RecordingOrientation
    private let imuReady: () -> Bool
    private let metadata: (CMSampleBuffer) -> Void
    private var audioInput: AVAssetWriterInput?
    private var audioFormat: CMFormatDescription?
    private var audioPending: [RAWBufferedSample] = []
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
    private var pending: [RAWBufferedSample] = []
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var frames = 0
    private var cadenceGuard = RAWCadenceGuard()
    private var captureDrops = 0
    private var preparationDrops = 0
    private var peakBuffered = 0
    private var maxGap = 0.0
    private var maxCallbackMS = 0.0
    private var maxMetadataMS = 0.0
    private var maxAppendMS = 0.0
    private var slowCallbacks = 0
    private var stopDeadline = 0.0
    #if DEBUG
    private static var consumedBufferFailure = false
    private let simulateBufferFailure: Bool
    private var simulatedStall = false
    #endif
    private let maxBuffered = 10 // Bound retained camera buffers; never grow with recording duration.

    private let slateMetadata: [AVMetadataItem]

    init(camera: AVCaptureDevice, codec: AVVideoCodecType, url: URL, queue controlQueue: DispatchQueue,
         preview: RAWWriterPreview, dedicatedStorage: Bool, slateMetadata: [AVMetadataItem] = [],
         prepareRecovery: @escaping () throws -> Void,
         orientation: RecordingOrientation, imuReady: @escaping () -> Bool,
         metadata: @escaping (CMSampleBuffer) -> Void,
         log: @escaping (String, [String: Any]) -> Void, started: @escaping (CMTime) -> Void,
         finished: @escaping (Error?) -> Void) {
        self.camera = camera; self.codec = codec; self.url = url
        self.queue = DispatchQueue(label: "GyroCine.rawRecording", qos: .userInitiated)
        self.slateMetadata = slateMetadata
        self.dedicatedStorage = dedicatedStorage
        self.prepareRecovery = { try controlQueue.sync(execute: prepareRecovery) }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        let firstOnly = args.contains("--writer-block-first-recording") && !Self.consumedBufferFailure
        simulateBufferFailure = args.contains("--writer-block-video") || firstOnly
        if firstOnly { Self.consumedBufferFailure = true }
        #endif
        // CameraManager state stays on its control queue; no per-frame round trip.
        self.log = { name, details in controlQueue.async { log(name, details) } }
        self.started = { pts in controlQueue.sync { started(pts) } }
        self.finished = { error in controlQueue.async { finished(error) } }
        self.orientation = orientation; self.imuReady = imuReady; self.metadata = metadata
        dataOutput = preview.dataOutput; audioOutput = preview.audioOutput
        requestedWB = preview.ready; readyWB = preview.ready
        super.init()
    }
    func arm() {
        captureQueue.async {
            self.dataOutput.setSampleBufferDelegate(self, queue: self.captureQueue)
            self.audioOutput.setSampleBufferDelegate(self, queue: self.captureQueue)
        }
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
    func abort(_ message: String) { queue.async { self.finish(self.failure(message)) } }

    func stop() {
        captureQueue.async {
            self.accepting = false
            // Already admitted samples are enqueued first; finish after their processing.
            self.queue.async { self.stopOnQueue() }
        }
    }

    private func stopOnQueue() {
        guard !completed, !stopping else { return }
        stopping = true
        stopDeadline = ProcessInfo.processInfo.systemUptime + 5
        drain()
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard accepting else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        let reason = String(describing: CMGetAttachment(sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil))
        queue.async {
            guard !self.stopping, !self.completed else { return }
            if self.firstPTS == nil { self.preparationDrops += 1 } else { self.captureDrops += 1 }
            self.log("raw_writer_capture_drop", ["pts": pts,
                "phase": self.firstPTS == nil ? "preparation" : "recording", "reason": reason])
        }
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard accepting else { return }
        let audio = output === audioOutput
        // Encoder setup is outside the recorded interval. Keep one startup video
        // sample in flight, rather than filling the recording buffer during setup.
        if !audio && !ingressArmed && preparingVideo { return }
        let preparationVideo = !audio && !ingressArmed
        let budget = audio ? audioBudget : videoBudget
        guard budget.acquire() else {
            if !ingressArmed { return }
            accepting = false
            queue.async {
                self.log("raw_writer_ingress_overflow", ["audio": audio, "limit": audio ? 32 : 10])
                self.finish(self.failure(audio ? "音频写入持续积压，已停止录制" :
                    "RAW 视频缓冲超过 10 帧，编码或存储写入跟不上，已停止录制并保留原片；请检查存储速度、剩余空间或降低录制规格"))
            }
            return
        }
        if preparationVideo { preparingVideo = true }
        let buffered = RAWBufferedSample(sample, budget: budget)
        queue.async {
            self.consume(buffered, audio: audio)
            if preparationVideo { self.captureQueue.async { self.preparingVideo = false } }
        }
    }
    private func consume(_ buffered: RAWBufferedSample, audio: Bool) {
        let sample = buffered.sample
        guard !stopping, !completed else { return }
        let callbackStart = ProcessInfo.processInfo.systemUptime
        #if DEBUG
        if !audio, !simulatedStall, let firstPTS,
           CMSampleBufferGetPresentationTimeStamp(sample).seconds - firstPTS.seconds > 3,
           let milliseconds = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--writer-stall-ms=") })
                .flatMap({ Double($0.dropFirst("--writer-stall-ms=".count)) }) {
            simulatedStall = true
            log("raw_writer_test_stall", ["milliseconds": milliseconds])
            Thread.sleep(forTimeInterval: min(0.5, max(0, milliseconds / 1000)))
        }
        #endif
        defer {
            let ms = (ProcessInfo.processInfo.systemUptime - callbackStart) * 1000
            maxCallbackMS = max(maxCallbackMS, ms)
            if firstPTS != nil && ms > 4 {
                slowCallbacks += 1
                if slowCallbacks <= 12 {
                    log("raw_writer_slow_callback", ["milliseconds": ms, "audio": audio,
                        "frame": frames, "pending": pending.count])
                }
            }
        }
        if audio {
            receivedAudio += 1
            if receivedAudio == 1 { log("raw_writer_first_audio", ["pts": CMSampleBufferGetPresentationTimeStamp(sample).seconds]) }
            audioFormat = CMSampleBufferGetFormatDescription(sample)
            guard let firstPTS else { return }
            guard CMSampleBufferGetPresentationTimeStamp(sample) >= firstPTS else { return }
            guard audioPending.count < 32 else { finish(failure("音频写入持续积压")); return }
            audioPending.append(buffered)
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
        // IMU pre-roll is an arming condition only. Its timestamp getters share
        // a lock with IMU disk writes; never wait on that lock for every video frame.
        guard readyWB, writer != nil || imuReady(), let audioFormat else { return }
        if writer == nil {
            do {
                let w = try AVAssetWriter(outputURL: url, fileType: .mov)
                if dedicatedStorage {
                    guard w.isProVideoStorageSupported else { throw failure("Writer 不支持专用存储") }
                    w.usesProVideoStorage = true
                }
                var settings: [String: Any]?
                if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                    settings = self.dataOutput.recommendedVideoSettings(forVideoCodecType: self.codec, assetWriterOutputFileType: .mov)
                    w.metadata = (self.dataOutput.recommendedMovieMetadata(forVideoCodecType: self.codec, assetWriterOutputFileType: .mov) ?? []) + self.slateMetadata
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
                    AVEncoderBitRateKey: asbd.mChannelsPerFrame == 1 ? 128_000 : 320_000]
                log("raw_writer_audio_format", ["sampleRate": asbd.mSampleRate, "channels": asbd.mChannelsPerFrame, "bitRate": audioSettings[AVEncoderBitRateKey] ?? 0])
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings, sourceFormatHint: audioFormat)
                audio.expectsMediaDataInRealTime = true
                guard w.canAdd(audio) else { throw failure("无法添加音频输入") }
                w.add(audio); audioInput = audio
                guard w.startWriting() else { throw w.error ?? failure("Writer 启动失败") }
                writer = w; input = i
                // Persist external access before the first recorded frame, off its deadline.
                try prepareRecovery()
                log("raw_writer_encoder_ready", ["file": url.path, "codec": codec.rawValue,
                    "dedicated": w.usesProVideoStorage, "settings": settings])
                captureQueue.async { self.ingressArmed = true }
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
            log("raw_writer_buffer_overflow", ["buffered": pending.count, "limit": maxBuffered])
            finish(failure("RAW 视频缓冲超过 10 帧，编码或存储写入跟不上，已停止录制并保留原片；请检查存储速度、剩余空间或降低录制规格")); return
        }
        let startupFrame = frames < 3
        let processingStart = ProcessInfo.processInfo.systemUptime
        if let lost = cadenceGuard.observe(CMSampleBufferGetPresentationTimeStamp(sample).seconds,
            fps: 1 / camera.activeVideoMinFrameDuration.seconds) {
            log("raw_writer_cadence_stop", ["missingFrames": lost, "windowSeconds": 5])
            finish(failure("检测到持续严重丢帧，已停止录制并保留原片。请检查存储持续写入速度，或降低编码质量、分辨率及帧率"))
            return
        }
        metadata(sample)
        let metadataEnd = ProcessInfo.processInfo.systemUptime
        maxMetadataMS = max(maxMetadataMS, (metadataEnd - processingStart) * 1000)
        pending.append(buffered)
        peakBuffered = max(peakBuffered, pending.count)
        drain()
        maxAppendMS = max(maxAppendMS, (ProcessInfo.processInfo.systemUptime - metadataEnd) * 1000)
        if startupFrame {
            log("raw_writer_startup_frame_timing", ["frame": frames,
                "metadataMS": (metadataEnd - processingStart) * 1000,
                "appendMS": (ProcessInfo.processInfo.systemUptime - metadataEnd) * 1000])
        }
    }
    private var retryScheduled = false
    private func drain() {
        guard !completed, let writer, let input else {
            if stopping && !completed { finish(failure("RAW 尚未开始录制")) }
            return
        }
        guard writer.status == .writing else { finish(writer.error ?? failure("Writer 意外停止")); return }
        #if DEBUG
        let simulateBlockedVideo = simulateBufferFailure && frames >= 5 && !stopping
        #else
        let simulateBlockedVideo = false
        #endif
        while !simulateBlockedVideo && !pending.isEmpty && input.isReadyForMoreMediaData {
            let buffered = pending.removeFirst()
            defer { withExtendedLifetime(buffered) {} }
            let sample = buffered.sample
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            guard input.append(sample) else { finish(writer.error ?? failure("RAW 帧写入失败")); return }
            if let lastPTS { maxGap = max(maxGap, CMTimeSubtract(pts, lastPTS).seconds) }
            lastPTS = pts; lastVideoDuration = CMSampleBufferGetDuration(sample); frames += 1
        }
        if let audioInput {
            while !audioPending.isEmpty && audioInput.isReadyForMoreMediaData {
                let audio = audioPending.removeFirst()
                defer { withExtendedLifetime(audio) {} }
                guard audioInput.append(audio.sample) else { finish(writer.error ?? failure("音频写入失败")); return }
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
        captureQueue.async { self.accepting = false }
        if let writer, writer.status == .writing, let input {
            input.markAsFinished(); audioInput?.markAsFinished()
            writer.finishWriting { self.queue.async { self.report(error) } }
        } else { report(error) }
    }
    private func report(_ error: Error?) {
        log("raw_writer_finished", ["file": url.path, "frames": frames, "captureDrops": captureDrops,
            "maxCallbackMS": maxCallbackMS, "maxMetadataMS": maxMetadataMS,
            "maxAppendMS": maxAppendMS, "slowCallbacks": slowCallbacks,
            "audioPackets": audioPackets, "receivedVideo": receivedVideo, "receivedAudio": receivedAudio, "rotation": orientation.degrees, "preparationDrops": preparationDrops, "peakBuffered": max(peakBuffered, videoBudget.peak), "peakAudioBuffered": audioBudget.peak, "maxGap": maxGap, "error": error.map { String(describing: $0) } ?? ""])
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
    private var lockAttempt = 0
    private var requestFrame = 0
    private var targetGains: AVCaptureDevice.WhiteBalanceGains?
    private var stableLockedFrames = 0
    private var lastObservedPTS = CMTime.invalid
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
        guard !ready else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if lockAttempt >= 3, videoCount - requestFrame >= 12, let target = targetGains {
            let actual = camera.deviceWhiteBalanceGains
            let pairs = [(actual.redGain, target.redGain), (actual.greenGain, target.greenGain), (actual.blueGain, target.blueGain)]
            let matched = pairs.allSatisfy { $0.0.isFinite && $0.1.isFinite && $0.0 >= 1 && abs($0.0 - $0.1) <= 0.01 }
            let fresh = pts.isValid && (!lastObservedPTS.isValid || CMTimeCompare(pts, lastObservedPTS) > 0)
            stableLockedFrames = camera.whiteBalanceMode == .locked && !camera.isAdjustingWhiteBalance && matched && fresh
                ? stableLockedFrames + 1 : 0
            lastObservedPTS = pts
            if stableLockedFrames >= 8 {
                // deviceWhiteBalanceGains is the current in-use state (SDK contract).
                // Require live, increasing RAW frames and stable target readback, not elapsed time.
                log("raw_preview_locked_readback", ["frames": stableLockedFrames,
                    "r": actual.redGain, "g": actual.greenGain, "b": actual.blueGain])
                markReady(pts, source: "locked_gain_readback", attempt: lockAttempt)
                return
            }
        }
        // A lock completion can be omitted although RAW frames continue flowing.
        // Retry against real frames; never treat a timeout or mode property as readiness.
        guard !requested || (videoCount - requestFrame >= 12 && lockAttempt < 3) else { return }
        requested = true
        lockAttempt += 1
        requestFrame = videoCount
        let attempt = lockAttempt
        do {
            try camera.lockForConfiguration()
            let gains = camera.deviceWhiteBalanceGains
            targetGains = gains
            let request = attempt == 1 || !camera.isLockingWhiteBalanceWithCustomDeviceGainsSupported
                ? AVCaptureDevice.currentWhiteBalanceGains : gains
            camera.setWhiteBalanceModeLocked(with: request) { [weak self] time in
                guard let self else { return }
                self.queue.async {
                    self.log("raw_preview_lock_callback", ["attempt": attempt,
                        "latestAttempt": self.lockAttempt, "valid": self.valid, "effectivePTS": time.seconds])
                    // AVFoundation delivers lock callbacks FIFO. An earlier request's
                    // real completion still proves this unchanged preview is locked.
                    guard self.valid, !self.ready else { return }
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--wb-drop-all-completions") ||
                        (attempt == 1 && ProcessInfo.processInfo.arguments.contains("--wb-drop-first-completion")) {
                        self.log("raw_preview_test_completion_dropped", [:]); return
                    }
                    #endif
                    self.markReady(time, source: "completion", attempt: attempt)
                }
            }
            camera.unlockForConfiguration()
            log("raw_preview_lock_requested", ["mode": camera.whiteBalanceMode.rawValue, "attempt": attempt, "video": videoCount])
        } catch { valid = false; completion(error) }
    }
    private func markReady(_ time: CMTime, source: String, attempt: Int) {
        guard valid, !ready else { return }
        ready = true
        log("raw_preview_ready", ["pts": time.seconds, "source": source, "video": videoCount,
            "audio": audioCount, "wbMode": camera.whiteBalanceMode.rawValue, "attempt": attempt])
        completion(nil)
    }

}
