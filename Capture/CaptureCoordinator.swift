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
    private var captureVideoOutput: AVCaptureVideoDataOutput?
    private var audioEnabled = true
    private var fileURL: URL?
    private var externalMovieURL: URL?
    private var frameEvidenceHandle: FileHandle?
    private let evidenceEncoder = JSONEncoder()
    private var previewFrameCount = 0

    var onState: ((RecordingState, String?) -> Void)?
    var onCompleted: ((URL, ClockEvidence?, Int, String?) -> Void)?
    var onCaptureFinished: (() -> Void)?
    var onExposureReading: ((Double, Float) -> Void)?

    func configure(audio: Bool, cameraID: String? = nil, shutter: ShutterSetting = .auto, codec: RecordingCodec = .hevc, requestedMode: CameraMode? = nil) {
        sessionQueue.async {
            self.onState?(.configuring, nil)
            do {
                let cameraGranted = awaitPermission(.video)
                guard cameraGranted else { throw RecorderError.cameraPermission }
                if audio && !awaitPermission(.audio) { throw RecorderError.microphonePermission }
                guard let device = cameraID.flatMap({ CameraCapabilityScanner.device(id: $0) }) ?? (cameraID == nil ? CameraCapabilityScanner.mainCamera() : nil) else { throw RecorderError.noCamera }
                guard let mode = CameraCapabilityScanner.modes(device: device, codec: codec).first(where: { $0 == requestedMode }),
                      let targetCodec = codec.avCodec else {
                    throw RecorderError.unavailable("This lens/system has no \(codec.label) requested mode")
                }
                self.codec = codec
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
                let capability: [String: Any] = ["camera": device.uniqueID, "formatIndex": mode.formatIndex,
                    "width": mode.width, "height": mode.height, "fps": mode.fps,
                    "requestedCodec": targetCodec.rawValue, "availableWriterCodecs": available.map(\.rawValue),
                    "availablePixelFormats": video.availableVideoPixelFormatTypes,
                    "storage": codec.isRAW ? "external storage required" : "internal Documents", "deferredStartEnabled": false]
                let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                try JSONSerialization.data(withJSONObject: capability, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("capture_capabilities_\(targetCodec.rawValue).json"))
                guard available.contains(targetCodec) else {
                    throw RecorderError.unavailable("\(codec.label) encoder unavailable for active format; available: \(available.map(\.rawValue))")
                }
                guard shutter.isSupported(by: device, mode: mode) else {
                    throw RecorderError.unavailable("Selected exposure limit is unsupported for the selected camera mode")
                }
                try device.lockForConfiguration()
                device.exposureMode = .continuousAutoExposure
                device.activeMaxExposureDuration = shutter.durationSeconds.map {
                    CMTime(seconds: $0, preferredTimescale: 1_000_000)
                } ?? .invalid
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

    func start(at url: URL) {
        sampleQueue.async {
            do {
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
                    DiagnosticsCollector.record("RAW external movie=\(external.path); copying to clip.mov after capture", folder: url.deletingLastPathComponent())
                }
                let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
                writer.metadata = [
                    (AVMetadataIdentifier.quickTimeMetadataMake, "Apple"),
                    (.quickTimeMetadataModel, RecorderIdentity.cameraModel),
                    (.quickTimeMetadataSoftware, "RawMotionRecorder"),
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
                    AVVideoCodecKey: AVVideoCodecType.hevc,
                    AVVideoWidthKey: mode.width, AVVideoHeightKey: mode.height,
                    AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: hevcBitRate]
                ]
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
                guard FileManager.default.createFile(atPath: evidenceURL.path, contents: nil) else {
                    throw RecorderError.unavailable("Cannot create video timing evidence")
                }
                self.frameEvidenceHandle = try FileHandle(forWritingTo: evidenceURL)
                self.writer = writer
                self.fileURL = url
                self.firstPTS = nil
                self.lastPTS = nil
                self.clockEvidence = nil
                self.frameCount = 0
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
            self.onState?(.finalizing, nil)
            do {
                try self.frameEvidenceHandle?.synchronize()
                try self.frameEvidenceHandle?.close()
            } catch { self.appendError = "Video timing evidence close failed: \(error.localizedDescription)" }
            self.frameEvidenceHandle = nil
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            writer.finishWriting {
                self.onCaptureFinished?()
                var error = self.appendError ?? writer.error?.localizedDescription
                if let external = self.externalMovieURL {
                    defer { external.stopAccessingSecurityScopedResource(); self.externalMovieURL = nil }
                    if error == nil {
                        do { try FileManager.default.copyItem(at: external, to: url) }
                        catch let copyError {
                            error = "RAW 已保存在 SSD，复制回手机失败: \(copyError.localizedDescription). SSD: \(external.path)"
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

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            previewFrameCount += 1
            if previewFrameCount % 30 == 1, let device {
                onExposureReading?(device.exposureDuration.seconds, device.iso)
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
