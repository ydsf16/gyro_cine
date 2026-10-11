import AVFoundation
import CoreMedia
import Foundation

final class CaptureCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "capture.session")
    private let sampleQueue = DispatchQueue(label: "capture.samples")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var lastPTS: CMTime?
    private var clockEvidence: ClockEvidence?
    private var frameCount = 0
    private var recordingActive = false
    private var appendError: String?
    private var device: AVCaptureDevice?
    private var mode: CameraMode?
    private var codec: RecordingCodec = .hevc
    private var recordingOrientation: RecordingOrientation = .landscapeRight
    private var color: RecordingColorSpace = .rec709
    private var captureVideoOutput: AVCaptureVideoDataOutput?
    private var audioEnabled = true
    private var fileURL: URL?
    private var externalMovieURL: URL?
    private var externalDestination = false
    private var frameEvidenceHandle: StagedRecordingLog?
    private let evidenceEncoder = JSONEncoder()
    private var previewFrameCount = 0
    private var droppedFrameCount = 0
    private var firstDroppedFrameReason: String?

    var onState: ((RecordingState, String?) -> Void)?
    var onCompleted: ((URL, ClockEvidence?, Int, String?) -> Void)?
    var onCaptureFinished: (() -> Void)?
    var onWhiteBalanceReading: ((Float, Float) -> Void)?
    var onExposureReading: ((Double, Float) -> Void)?
    var onAvailableWriterCodecs: (([AVVideoCodecType]) -> Void)?

    func configure(audio: Bool, cameraID: String? = nil, shutter: ShutterSetting = .auto, codec: RecordingCodec = .hevc, requestedMode: CameraMode? = nil, controls: CameraControls = CameraControls(), color: RecordingColorSpace = .rec709) {
        sessionQueue.async {
            self.onState?(.configuring, nil)
            do {
                let cameraGranted = awaitPermission(.video)
                guard cameraGranted else { throw RecorderError.cameraPermission }
                if audio && !awaitPermission(.audio) { throw RecorderError.microphonePermission }
                guard let device = cameraID.flatMap({ CameraCapabilityScanner.device(id: $0) }) ?? (cameraID == nil ? CameraCapabilityScanner.mainCamera() : nil) else { throw RecorderError.noCamera }
                guard let mode = CameraCapabilityScanner.modes(device: device, codec: codec, color: codec.isRAW ? nil : color).first(where: { $0 == requestedMode }),
                      let targetCodec = codec.avCodec else {
                    throw RecorderError.unavailable("This lens/system has no \(codec.label) requested mode")
                }
                self.codec = codec
                self.color = color
                self.device = device
                self.mode = mode
                self.audioEnabled = audio
                self.session.beginConfiguration()
                var configurationOpen = true
                defer { if configurationOpen { self.session.commitConfiguration() } }
                self.session.sessionPreset = .inputPriority
                self.session.automaticallyConfiguresCaptureDeviceForWideColor = false
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                try device.lockForConfiguration()
                device.activeFormat = device.formats[mode.formatIndex]
                if !codec.isRAW { device.activeColorSpace = color.captureSpace }
                device.videoZoomFactor = 1.0
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                if codec.isRAW {
                    guard device.isWhiteBalanceModeSupported(.locked) else {
                        device.unlockForConfiguration()
                        throw RecorderError.unavailable("RAW requires locked white balance")
                    }
                    device.setWhiteBalanceModeLocked(with: device.deviceWhiteBalanceGains, completionHandler: nil)
                } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                    device.whiteBalanceMode = .continuousAutoWhiteBalance
                }
                device.unlockForConfiguration()
                let cameraInput = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(cameraInput) else { throw RecorderError.unavailable("Cannot add camera input") }
                self.session.addInput(cameraInput)
                let video = AVCaptureVideoDataOutput()
                video.alwaysDiscardsLateVideoFrames = false
                video.setSampleBufferDelegate(self, queue: self.sampleQueue)
                guard self.session.canAddOutput(video) else { throw RecorderError.unavailable("Cannot add video output") }
                self.session.addOutput(video)
                self.captureVideoOutput = video
                if codec.isRAW { video.videoSettings = [:] }
                else if color == .hlg || color == .appleLog {
                    video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange]
                }
                if #available(iOS 26.0, *), video.isDeferredStartSupported {
                    video.isDeferredStartEnabled = false
                }
                if let connection = video.connection(with: .video) {
                    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = .off }
                    if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                    if connection.isCameraIntrinsicMatrixDeliverySupported { connection.isCameraIntrinsicMatrixDeliveryEnabled = true }
                }
                if audio {
                    guard let microphone = AVCaptureDevice.default(for: .audio) else { throw RecorderError.unavailable("Microphone unavailable") }
                    let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                    guard self.session.canAddInput(microphoneInput) else { throw RecorderError.unavailable("Cannot add microphone input") }
                    self.session.addInput(microphoneInput)
                    let output = AVCaptureAudioDataOutput()
                    output.setSampleBufferDelegate(self, queue: self.sampleQueue)
                    guard self.session.canAddOutput(output) else { throw RecorderError.unavailable("Cannot add audio output") }
                    self.session.addOutput(output)
                }
                self.session.commitConfiguration()
                configurationOpen = false
                self.session.startRunning()
                let available = video.availableVideoCodecTypesForAssetWriter(writingTo: .mov)
                self.onAvailableWriterCodecs?(available)
                let capability: [String: Any] = ["camera": device.uniqueID, "formatIndex": mode.formatIndex,
                    "width": mode.width, "height": mode.height, "fps": mode.fps,
                    "requestedCodec": targetCodec.rawValue, "availableWriterCodecs": available.map(\.rawValue),
                    "availablePixelFormats": video.availableVideoPixelFormatTypes,
                    "storage": codec.isRAW ? "external storage required" : "internal Documents", "deferredStartEnabled": false]
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GyroCineDiagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: capability, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("capture_capabilities_\(targetCodec.rawValue).json"))
                guard available.contains(targetCodec) else {
                    throw RecorderError.unavailable("\(codec.label) encoder unavailable for active format; available: \(available.map(\.rawValue))")
                }
                guard shutter.isSupported(by: device, mode: mode) else {
                    throw RecorderError.unavailable("Selected exposure limit is unsupported for the selected camera mode")
                }
                try device.lockForConfiguration()
                do { try controls.apply(to: device, fps: mode.fps, shutter: shutter, raw: codec.isRAW) }
                catch { device.unlockForConfiguration(); throw error }
                // Adding inputs / configuring exposure can reset frame durations.
                // Apply the requested cadence last, after the session is running.
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                let actualMin = device.activeVideoMinFrameDuration.seconds
                let actualMax = device.activeVideoMaxFrameDuration.seconds
                device.unlockForConfiguration()
                var configuredCapability = capability
                configuredCapability["configuredMinFrameDurationSeconds"] = actualMin
                configuredCapability["configuredMaxFrameDurationSeconds"] = actualMax
                try JSONSerialization.data(withJSONObject: configuredCapability, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("capture_capabilities_\(targetCodec.rawValue).json"))
                guard abs(actualMin - frameDuration.seconds) < 0.000001,
                      abs(actualMax - frameDuration.seconds) < 0.000001 else {
                    throw RecorderError.unavailable("Camera did not accept requested frame rate")
                }
                self.onExposureReading?(device.exposureDuration.seconds, device.iso)
                self.onState?(.ready, nil)
            } catch { self.onState?(.failed, error.localizedDescription) }
        }
    }

    /// Changes sensor controls on the session queue without rebuilding inputs or the writer.
    func updateControls(_ controls: CameraControls, shutter: ShutterSetting, completion: @escaping (String?) -> Void) {
        sessionQueue.async {
            guard let device = self.device, let mode = self.mode, self.session.isRunning else {
                completion("相机尚未准备好"); return
            }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try controls.apply(to: device, fps: mode.fps, shutter: shutter, raw: self.codec.isRAW)
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                self.onExposureReading?(device.exposureDuration.seconds, device.iso)
                let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                self.onWhiteBalanceReading?(wb.temperature, wb.tint)
                completion(nil)
            } catch { completion(error.localizedDescription) }
        }
    }

    func start(at url: URL, orientation: RecordingOrientation, externalDestination: Bool) {
        sampleQueue.async {
            do {
                self.recordingOrientation = orientation
                self.externalDestination = externalDestination
                guard let mode = self.mode else { throw RecorderError.unavailable("Camera not configured") }
                var outputURL = url
                if self.codec.isRAW {
                    guard AVExternalStorageDevice.authorizationStatus == .authorized,
                          let storage = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.first(where: { $0.isConnected }),
                          storage.freeSize >= 2_000_000_000,
                          let external = try storage.nextAvailableURLs(withPathExtensions: ["mov"]).first,
                          external.startAccessingSecurityScopedResource() else {
                        throw RecorderError.unavailable("ProRes RAW 需要已授权且至少有 2 GB 空间的外接 SSD")
                    }
                    outputURL = external
                    self.externalMovieURL = external
                    DiagnosticsCollector.record("RAW external movie=\(external.path); final destination=\(url.path)", folder: url.deletingLastPathComponent())
                }
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                writer.metadata = [
                    (AVMetadataIdentifier.quickTimeMetadataMake, "Apple"),
                    (.quickTimeMetadataModel, RecorderIdentity.cameraModel),
                    (.quickTimeMetadataSoftware, "GyroCine"),
                    (.quickTimeMetadataCreationDate, ISO8601DateFormatter().string(from: Date()))
                ].map { identifier, value in
                    let item = AVMutableMetadataItem()
                    item.identifier = identifier
                    item.value = value as NSString
                    return item
                }
                let pixelRatio = Double(mode.width * mode.height) / 8_294_400.0
                let frameRateRatio = Double(mode.fps) / 30.0
                let hevcBitRate = Int(40_000_000.0 * pixelRatio * frameRateRatio)
                var outputSettings: [String: Any] = [
                    AVVideoCodecKey: self.codec.avCodec ?? .hevc,
                    AVVideoWidthKey: mode.width, AVVideoHeightKey: mode.height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: hevcBitRate]
                ]
                if !self.codec.isRAW {
                    guard let settings = self.captureVideoOutput?.recommendedVideoSettings(forVideoCodecType: self.codec.avCodec ?? .hevc, assetWriterOutputFileType: .mov) else {
                        throw RecorderError.unavailable("当前色彩空间没有可用的写入参数")
                    }
                    if self.color != .rec709 || self.codec.isProRes { outputSettings = settings; outputSettings[AVVideoCodecKey] = self.codec.avCodec }
                    else { outputSettings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                        AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] }
                }
                if self.codec.isRAW {
                    guard #available(iOS 26.0, *), let output = self.captureVideoOutput,
                          let codec = self.codec.avCodec,
                          let settings = output.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mov, outputFileURL: outputURL) else {
                        throw RecorderError.unavailable("No recommended ProRes RAW settings for external storage")
                    }
                    outputSettings = settings
                    guard let metadata = output.recommendedMovieMetadata(forVideoCodecType: codec, assetWriterOutputFileType: .mov) else {
                        throw RecorderError.unavailable("Missing required RAW movie metadata")
                    }
                    writer.metadata += metadata
                }
                guard writer.canApply(outputSettings: outputSettings, forMediaType: .video) else {
                    throw RecorderError.unavailable("AssetWriter rejected \(self.codec.label) settings")
                }
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: outputSettings)
                video.expectsMediaDataInRealTime = true
                // QuickTime track transform rotates presentation without processing RAW Bayer buffers.
                video.transform = orientation.movieTransform(width: mode.width, height: mode.height)
                guard writer.canAdd(video) else { throw RecorderError.noHEVC }
                writer.add(video)
                self.videoInput = video
                if self.audioEnabled {
                    let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVNumberOfChannelsKey: 1,
                        AVSampleRateKey: 48_000,
                        AVEncoderBitRateKey: 128_000
                    ])
                    audio.expectsMediaDataInRealTime = true
                    if writer.canAdd(audio) { writer.add(audio); self.audioInput = audio }
                    else { throw RecorderError.unavailable("Cannot add AAC audio writer input") }
                }
                guard writer.startWriting() else { throw writer.error ?? RecorderError.unavailable("Writer did not start") }
                let evidenceURL = url.deletingLastPathComponent().appendingPathComponent("video_samples.jsonl")
                self.frameEvidenceHandle = try StagedRecordingLog(destination: evidenceURL)
                self.writer = writer
                self.fileURL = url
                self.firstPTS = nil
                self.lastPTS = nil
                self.clockEvidence = nil
                self.frameCount = 0
                self.droppedFrameCount = 0
                self.firstDroppedFrameReason = nil
                self.appendError = nil
                self.recordingActive = true
                self.onState?(.recording, nil)
            } catch {
                self.externalMovieURL?.stopAccessingSecurityScopedResource()
                self.externalMovieURL = nil
                self.onState?(.failed, error.localizedDescription)
            }
        }
    }

    func stop() {
        sampleQueue.async {
            guard self.recordingActive, let writer = self.writer, let url = self.fileURL else { return }
            self.recordingActive = false
            DiagnosticsCollector.record("capture dropped callbacks=\(self.droppedFrameCount) firstReason=\(self.firstDroppedFrameReason ?? "none")", folder: url.deletingLastPathComponent())
            self.onState?(.finalizing, nil)
            do {
                try self.frameEvidenceHandle?.close()
            } catch { self.appendError = "Video timing evidence close failed: \(error.localizedDescription)" }
            let evidenceLog = self.frameEvidenceHandle
            self.frameEvidenceHandle = nil
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                self.onCaptureFinished?()
                var error = self.appendError ?? writer.error?.localizedDescription
                do { try evidenceLog?.publish() }
                catch let logError { error = error ?? logError.localizedDescription }
                if let external = self.externalMovieURL {
                    defer { external.stopAccessingSecurityScopedResource(); self.externalMovieURL = nil }
                    if error == nil {
                        do {
                            if self.externalDestination { try FileManager.default.moveItem(at: external, to: url) }
                            else { try FileManager.default.copyItem(at: external, to: url) }
                        }
                        catch let copyError {
                            error = "RAW 已保存在 SSD，归档到录制文件夹失败: \(copyError.localizedDescription). SSD: \(external.path)"
                        }
                    }
                }
                self.sampleQueue.async {
                    self.onCompleted?(url, self.clockEvidence, self.frameCount, error)
                    self.writer = nil
                    self.videoInput = nil
                    self.audioInput = nil
                }
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard recordingActive, output is AVCaptureVideoDataOutput else { return }
        droppedFrameCount += 1
        if firstDroppedFrameReason == nil {
            let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
            firstDroppedFrameReason = "PTS=\(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))) reason=\(String(describing: reason))"
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            previewFrameCount += 1
            if previewFrameCount % 30 == 1, let device {
                onExposureReading?(device.exposureDuration.seconds, device.iso)
                let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                onWhiteBalanceReading?(wb.temperature, wb.tint)
            }
        }
        guard recordingActive, let writer else { return }
        guard writer.status == .writing else {
            if writer.status == .failed {
                recordingActive = false
                onState?(.failed, writer.error?.localizedDescription ?? "Video writer failed")
            }
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output is AVCaptureVideoDataOutput {
            let hostPTS: Double
            do { hostPTS = try ClockAligner.hostTime(pts, clock: session.synchronizationClock) }
            catch {
                appendError = error.localizedDescription
                stop()
                return
            }
            if firstPTS == nil {
                firstPTS = pts
                clockEvidence = ClockAligner.evidence(firstPTS: pts, hostPTS: hostPTS,
                    callbackHostTime: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
                writer.startSession(atSourceTime: pts)
            }
            guard let videoInput, videoInput.isReadyForMoreMediaData else {
                appendError = "Video writer backpressure: frame dropped"
                return
            }
            if videoInput.append(sampleBuffer) {
                frameCount += 1
                lastPTS = pts
                let evidence = CaptureFrameEvidence(hostPTSSeconds: hostPTS, sourcePTSSeconds: CMTimeGetSeconds(pts),
                    cameraIntrinsicMatrix: CaptureFrameEvidence.intrinsicMatrix(sampleBuffer),
                    intrinsicSource: "kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix; native unrotated output buffer coordinates",
                    activeVideoStabilizationMode: connection.activeVideoStabilizationMode.rawValue,
                    deviceExposureDurationAtCallbackSeconds: device?.exposureDuration.seconds,
                    deviceISOAtCallback: device?.iso)
                if frameCount % 30 == 1, let exposure = evidence.deviceExposureDurationAtCallbackSeconds,
                   let iso = evidence.deviceISOAtCallback {
                    onExposureReading?(exposure, iso)
                }
                do { try frameEvidenceHandle?.write(contentsOf: evidenceEncoder.encode(evidence) + Data([0x0A])) }
                catch { appendError = "Video timing evidence write failed: \(error.localizedDescription)" }
            }
            else { appendError = writer.error?.localizedDescription ?? "Video append failed" }
        } else if firstPTS != nil, let audioInput, audioInput.isReadyForMoreMediaData {
            if !audioInput.append(sampleBuffer) { appendError = writer.error?.localizedDescription ?? "Audio append failed" }
        }
    }
}

private func awaitPermission(_ type: AVMediaType) -> Bool {
    let semaphore = DispatchSemaphore(value: 0)
    var granted = false
    switch AVCaptureDevice.authorizationStatus(for: type) {
    case .authorized: return true
    case .notDetermined:
        AVCaptureDevice.requestAccess(for: type) { result in granted = result; semaphore.signal() }
        semaphore.wait()
        return granted
    default: return false
    }
}
