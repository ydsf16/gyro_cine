import AVFoundation

final class WriterProbe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let queue = DispatchQueue(label: "probe.writer")
    let session = AVCaptureSession()
    let output = AVCaptureVideoDataOutput()
    let log: (String, [String: Any]) -> Void
    let finished: () -> Void
    var observers: [NSObjectProtocol] = []
    var writer: AVAssetWriter?
    var input: AVAssetWriterInput?
    var settings: [String: Any] = [:]
    var attempted = false
    var whiteBalanceReady = false
    var whiteBalanceRequested = false
    var camera: AVCaptureDevice?
    var firstPTS: CMTime?
    let codec = ProcessInfo.processInfo.arguments.contains("--hq") ? "aprh" : "aprn"
    let duration: Double = ProcessInfo.processInfo.arguments.contains("--long") ? 30 : 5
    var frames = 0
    var dropped = 0
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("UITEST_writer_\(UUID().uuidString).mov")
    init(log: @escaping (String, [String: Any]) -> Void, finished: @escaping () -> Void) {
        self.log = log; self.finished = finished
        super.init()
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification, AVCaptureSession.runtimeErrorNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { note in
                self.queue.async { self.log("session_notification", ["name": note.name.rawValue, "info": String(describing: note.userInfo)]) }
            })
        }
    }
    func run() { queue.async { self.setup() } }
    private func setup() {
        do {
            guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else { return }
            self.camera = camera
            let cameraInput = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration(); session.sessionPreset = .inputPriority
            session.addInput(cameraInput); session.addOutput(output)
            output.automaticallyConfiguresOutputBufferDimensions = false
            output.deliversPreviewSizedOutputBuffers = false
            output.videoSettings = [:]
            output.alwaysDiscardsLateVideoFrames = true
            output.setSampleBufferDelegate(self, queue: queue)
            // Select by capability, never assume the production app's format index.
            var selected = false
            for (index, format) in camera.formats.enumerated() {
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == 4224 && dims.height == 2240,
                      format.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 30 && $0.maxFrameRate >= 30 }) else { continue }
                try camera.lockForConfiguration()
                camera.activeFormat = format
                camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
                if camera.isWhiteBalanceModeSupported(.locked) { camera.whiteBalanceMode = .locked }
                camera.unlockForConfiguration()
                let codecs = output.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
                if codecs.contains(AVVideoCodecType(rawValue: codec)) {
                    log("writer_format", ["index": index, "codecs": codecs.map(\.rawValue)])
                    selected = true; break
                }
            }
            session.commitConfiguration()
            guard selected else { log("writer_no_raw_format", [:]); finished(); return }
            output.connection(with: .video)?.videoRotationAngle = 0
            try camera.lockForConfiguration()
            camera.setWhiteBalanceModeLocked(with: camera.deviceWhiteBalanceGains, completionHandler: nil)
            camera.unlockForConfiguration()
            session.startRunning()
            whiteBalanceReady = false
            log("writer_wb_before_samples", ["locked": whiteBalanceReady])
            let w = try AVAssetWriter(outputURL: url, fileType: .mov)
            writer = w
            log("writer_pre_settings_support", ["support": w.isProVideoStorageSupported])
            if w.isProVideoStorageSupported {
                w.usesProVideoStorage = true
                log("writer_pre_settings_enabled", ["enabled": w.usesProVideoStorage])
            }
            for variant in ["localURL", "nilURL", "noURL"] {
                var candidate: [String: Any]?
                let error = ExceptionGuard.run {
                    if variant == "noURL" {
                        candidate = self.output.recommendedVideoSettings(forVideoCodecType: AVVideoCodecType(rawValue: self.codec), assetWriterOutputFileType: .mov)
                    } else {
                        candidate = self.output.recommendedVideoSettings(forVideoCodecType: AVVideoCodecType(rawValue: self.codec), assetWriterOutputFileType: .mov, outputFileURL: variant == "localURL" ? self.url : nil)
                    }
                }
                log("writer_recommendation", ["variant": variant, "error": error ?? "", "settings": candidate ?? [:]])
                if let candidate { settings = candidate }
            }
            if settings.isEmpty {
                // Minimal public compression settings; sourceFormatHint comes from actual RAW sample.
                let dims = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
                settings = [AVVideoCodecKey: codec, AVVideoWidthKey: dims.width, AVVideoHeightKey: dims.height]
                log("writer_minimal_settings", settings)
            }
            queue.asyncAfter(deadline: .now() + 15) {
                if !self.attempted { self.log("writer_no_samples", [:]); self.session.stopRunning(); self.finished() }
            }
        } catch { log("writer_setup_error", ["error": String(describing: error)]); session.stopRunning(); finished() }
    }
    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        log("capture_drop", ["pts": CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds])
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        if !whiteBalanceRequested, let camera {
            whiteBalanceRequested = true
            do {
                try camera.lockForConfiguration()
                camera.setWhiteBalanceModeLocked(with: camera.deviceWhiteBalanceGains) { effectiveTime in
                    self.queue.async {
                        self.whiteBalanceReady = true
                        self.log("writer_wb_effective", ["time": effectiveTime.seconds, "mode": camera.whiteBalanceMode.rawValue])
                    }
                }
                camera.unlockForConfiguration()
                log("writer_wb_requested_after_frame", [:])
            } catch { log("writer_wb_error", ["error": String(describing: error)]) }
            return
        }
        if attempted, let writer, writer.status == .failed {
            log("writer_async_failed", ["error": String(describing: writer.error), "frames": frames])
            session.stopRunning(); finished(); return
        }
        guard whiteBalanceReady, !attempted || writer?.status == .writing else { return }
        if !attempted {
            attempted = true
            do {
                let w = try writer ?? AVAssetWriter(outputURL: url, fileType: .mov)
                log("writer_empty_support", ["support": w.isProVideoStorageSupported])
                guard let hint = CMSampleBufferGetFormatDescription(sample), !settings.isEmpty else {
                    log("writer_missing_settings", [:]); session.stopRunning(); finished(); return
                }
                let i = AVAssetWriterInput(mediaType: .video, outputSettings: settings, sourceFormatHint: hint)
                i.expectsMediaDataInRealTime = true
                guard w.canAdd(i) else { log("writer_cannot_add", [:]); session.stopRunning(); finished(); return }
                w.add(i)
                log("writer_configured_support", ["support": w.isProVideoStorageSupported,
                    "sampleSubtype": CMFormatDescriptionGetMediaSubType(hint)])
                guard w.isProVideoStorageSupported else { session.stopRunning(); finished(); return }
                log("writer_before_enable_again", [:])
                w.usesProVideoStorage = true
                log("writer_before_metadata", [:])
                let metadataError = ExceptionGuard.run {
                    w.metadata = self.output.recommendedMovieMetadata(forVideoCodecType: AVVideoCodecType(rawValue: self.codec), assetWriterOutputFileType: .mov) ?? []
                }
                if let metadataError { log("writer_metadata_error", ["error": metadataError]) }
                log("writer_before_start", [:])
                guard w.startWriting() else { log("writer_start_failed", ["error": String(describing: w.error)]); session.stopRunning(); finished(); return }
                log("writer_started", [:])
                firstPTS = CMSampleBufferGetPresentationTimeStamp(sample)
                w.startSession(atSourceTime: firstPTS!)
                writer = w; input = i
            } catch { log("writer_error", ["error": String(describing: error)]); session.stopRunning(); finished(); return }
        }
        guard let w = writer, let i = input, let firstPTS else { return }
        if i.isReadyForMoreMediaData {
            if frames == 0 { log("writer_before_first_append", [:]) }
            if i.append(sample) { frames += 1; if frames == 1 || frames % 30 == 0 { log("writer_frames", ["frames": frames]) } }
            else { log("writer_append_failed", ["error": String(describing: w.error)]); session.stopRunning(); finished(); return }
        } else { dropped += 1 }
        if CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), firstPTS).seconds >= duration {
            session.stopRunning(); i.markAsFinished()
            w.finishWriting { self.queue.async {
                self.log("writer_finished", ["status": w.status.rawValue, "error": String(describing: w.error),
                    "frames": self.frames, "backpressureDrops": self.dropped, "file": self.url.lastPathComponent])
                self.finished()
            } }
        }
    }
}
