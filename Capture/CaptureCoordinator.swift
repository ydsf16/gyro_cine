import AVFoundation
import CoreMedia
import Foundation

final class CaptureCoordinator: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureFileOutputRecordingDelegate {
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
    private let focusDiagnosticsQueue = DispatchQueue(label: "capture.focus.diagnostics", qos: .utility)
    private var focusDiagnostics: [[String: Any]] = [] // accessed only on focusDiagnosticsQueue
    private var focusObserver: NSObjectProtocol?
    private var focusAdjustmentObservation: NSKeyValueObservation?
    private var focusRecoveryID: UUID?
    private var focusRecoverySawAdjustment = false
    private var device: AVCaptureDevice?
    private var mode: CameraMode?
    private var codec: RecordingCodec = .hevc
    private var recordingOrientation: RecordingOrientation = .landscapeRight
    private var color: RecordingColorSpace = .rec709
    private var captureVideoOutput: AVCaptureVideoDataOutput?
    // Temporary AF comparison path: the system records the MOV without our frame-copy writer.
    private var captureMovieOutput: AVCaptureMovieFileOutput?
    private var focusPollToken = UUID()
    private var audioEnabled = true
    private var fileURL: URL?
    private var externalMovieURL: URL?
    private var externalDestination = false
    private var frameEvidenceHandle: StagedRecordingLog?
    private let evidenceEncoder = JSONEncoder()
    private var frameCopier = CaptureFrameCopier()
    private let stopRequestLock = NSLock()
    private var stopRequested = false
    private struct PendingFrame {
        let sample: CMSampleBuffer
        let pts: CMTime
        let evidence: CaptureFrameEvidence
    }
    private var pendingVideo = PendingVideoQueue<PendingFrame>(capacity: 48)
    private var peakPendingVideo = 0
    private var previewFrameCount = 0
    private var droppedFrameCount = 0
    private var firstDroppedFrameReason: String?
    private var videoCallbackCount = 0
    private var writerNotReadyCallbacks = 0
    private var maxCallbackLagMs = 0.0
    private var maxFrameCopyMs = 0.0
    private var maxVideoDrainMs = 0.0
    private var maxSourceGapMs = 0.0
    private var previousSourcePTSSeconds: Double?

    var onState: ((RecordingState, String?) -> Void)?
    var onCompleted: ((URL, ClockEvidence?, Int, String?) -> Void)?
    var onCaptureFinished: (() -> Void)?
    var onWhiteBalanceReading: ((Float, Float) -> Void)?
    var onExposureReading: ((Double, Float) -> Void)?
    var onFocusReading: ((Float, AVCaptureDevice.FocusMode, Bool) -> Void)?
    var onInternalRAWSupport: ((Bool?, String) -> Void)?
    var onAvailableWriterCodecs: (([AVVideoCodecType]) -> Void)?
    var onMovieFileCompleted: ((URL, String?) -> Void)?

    deinit { if let observer = focusObserver { NotificationCenter.default.removeObserver(observer) } }

    func configure(audio: Bool, cameraID: String? = nil, shutter: ShutterSetting = .auto, codec: RecordingCodec = .hevc, requestedMode: CameraMode? = nil, controls: CameraControls = CameraControls(), color: RecordingColorSpace = .rec709) {
        sessionQueue.async {
            self.onInternalRAWSupport?(nil, "点击录制时检测 RAW 内录能力")
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
                // Stop delivery and drain old callbacks before replacing device/mode state.
                // Sample callbacks read that state and must never see the next lens mid-switch.
                if let observer = self.focusObserver { NotificationCenter.default.removeObserver(observer); self.focusObserver = nil }
                self.focusAdjustmentObservation = nil
                self.focusRecoveryID = nil
                self.focusPollToken = UUID()
                self.session.stopRunning()
                self.captureVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
                self.sampleQueue.sync {}
                self.codec = codec
                self.color = color
                self.device = device
                self.mode = mode
                self.audioEnabled = audio
                let rawAFMinimalComparison = codec.isRAW
                let preSessionFormatIndex = device.formats.firstIndex(where: { $0 === device.activeFormat }) ?? -1
                let avoidRAWStabilizationOverride = codec.isRAW && device.deviceType == .builtInWideAngleCamera
                    && mode.formatIndex == 69
                self.session.beginConfiguration()
                var configurationOpen = true
                defer { if configurationOpen { self.session.commitConfiguration() } }
                self.session.sessionPreset = .inputPriority
                if !rawAFMinimalComparison { self.session.automaticallyConfiguresCaptureDeviceForWideColor = false }
                self.session.inputs.forEach(self.session.removeInput)
                self.session.outputs.forEach(self.session.removeOutput)
                // Compare the test app's RAW setup order: add the camera first,
                // start the session, then select the requested RAW format.
                let liveRAWFormatSelection = codec.isRAW
                if !rawAFMinimalComparison {
                    try device.lockForConfiguration()
                    device.activeFormat = device.formats[liveRAWFormatSelection ? 26 : mode.formatIndex]
                    if !codec.isRAW { device.activeColorSpace = color.captureSpace }
                    device.videoZoomFactor = 1.0
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                    if codec.isRAW {
                        guard device.isWhiteBalanceModeSupported(.locked) else {
                            device.unlockForConfiguration()
                            throw RecorderError.unavailable("RAW requires locked white balance")
                        }
                        let gains = CameraControls.validWhiteBalanceGains(device.deviceWhiteBalanceGains,
                            maximum: device.maxWhiteBalanceGain)
                        device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
                    } else if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                        device.whiteBalanceMode = .continuousAutoWhiteBalance
                    }
                    device.unlockForConfiguration()
                }
                let cameraInput = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(cameraInput) else { throw RecorderError.unavailable("Cannot add camera input") }
                self.session.addInput(cameraInput)
                let video = AVCaptureMovieFileOutput()
                guard self.session.canAddOutput(video) else { throw RecorderError.unavailable("Cannot add video output") }
                self.session.addOutput(video)
                self.captureVideoOutput = nil
                self.captureMovieOutput = video
                if !rawAFMinimalComparison, let connection = video.connection(with: .video) {
                    if !avoidRAWStabilizationOverride && connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .off
                    }
                    if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
                    connection.automaticallyAdjustsVideoMirroring = false
                    if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
                }
                if audio && !rawAFMinimalComparison {
                    guard let microphone = AVCaptureDevice.default(for: .audio) else { throw RecorderError.unavailable("Microphone unavailable") }
                    let microphoneInput = try AVCaptureDeviceInput(device: microphone)
                    guard self.session.canAddInput(microphoneInput) else { throw RecorderError.unavailable("Cannot add microphone input") }
                    self.session.addInput(microphoneInput)
                }
                self.session.commitConfiguration()
                configurationOpen = false
                self.session.startRunning()
                if liveRAWFormatSelection {
                    self.session.beginConfiguration()
                    do {
                        try device.lockForConfiguration()
                        device.activeFormat = device.formats[mode.formatIndex]
                        let duration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                        device.activeVideoMinFrameDuration = duration
                        device.activeVideoMaxFrameDuration = duration
                        device.unlockForConfiguration()
                        guard video.availableVideoCodecTypes.contains(targetCodec),
                              let connection = video.connection(with: .video) else {
                            throw RecorderError.unavailable("RAW movie codec unavailable after format change")
                        }
                        video.setOutputSettings([AVVideoCodecKey: targetCodec], for: connection)
                        self.session.commitConfiguration()
                    } catch {
                        self.session.commitConfiguration()
                        throw error
                    }
                }
                let available = video.availableVideoCodecTypes
                self.onAvailableWriterCodecs?(available)
                let capability: [String: Any] = ["camera": device.uniqueID, "formatIndex": mode.formatIndex,
                    "width": mode.width, "height": mode.height, "fps": mode.fps,
                    "requestedCodec": targetCodec.rawValue, "availableWriterCodecs": available.map(\.rawValue),
                    "availablePixelFormats": [Int](),
                    "storage": codec.isRAW ? "destination capability checked at runtime" : "internal Documents", "output": "AVCaptureMovieFileOutput AF test"]
                let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("GyroCineDiagnostics", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: capability, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("capture_capabilities_\(targetCodec.rawValue).json"))
                guard available.contains(targetCodec) else {
                    throw RecorderError.unavailable("\(codec.label) encoder unavailable for active format; available: \(available.map(\.rawValue))")
                }
                guard let movieConnection = video.connection(with: .video) else {
                    throw RecorderError.unavailable("Movie output has no video connection")
                }
                if !liveRAWFormatSelection {
                    video.setOutputSettings([AVVideoCodecKey: targetCodec], for: movieConnection)
                }
                guard shutter.isSupported(by: device, mode: mode) else {
                    throw RecorderError.unavailable("Selected exposure limit is unsupported for the selected camera mode")
                }
                try device.lockForConfiguration()
                do {
                    if !rawAFMinimalComparison {
                        try controls.apply(to: device, fps: mode.fps, shutter: shutter, raw: codec.isRAW)
                    }
                }
                catch { device.unlockForConfiguration(); throw error }
                // AF comparison: set continuous focus without touching face-driven behavior.
                if !rawAFMinimalComparison && device.isFocusModeSupported(.continuousAutoFocus) {
                    device.focusMode = .continuousAutoFocus
                }
                if !rawAFMinimalComparison { device.isSubjectAreaChangeMonitoringEnabled = false }
                // Adding inputs / configuring exposure can reset frame durations.
                // Apply the requested cadence last, after the session is running.
                let frameDuration = CMTime(value: 1, timescale: CMTimeScale(mode.fps))
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
                let actualMin = device.activeVideoMinFrameDuration.seconds
                let actualMax = device.activeVideoMaxFrameDuration.seconds
                device.unlockForConfiguration()
                self.recordFocusState(device, event: "configured")
                var configuredCapability = capability
                configuredCapability["focusMode"] = device.focusMode.rawValue
                configuredCapability["smoothAutoFocusSupported"] = device.isSmoothAutoFocusSupported
                configuredCapability["smoothAutoFocusEnabled"] = device.isSmoothAutoFocusEnabled
                configuredCapability["autoFocusRangeRestriction"] = device.autoFocusRangeRestriction.rawValue
                configuredCapability["autoFocusSupported"] = device.isFocusModeSupported(.autoFocus)
                configuredCapability["autoFocusSystem"] = device.activeFormat.autoFocusSystem.rawValue
                configuredCapability["minimumFocusDistanceMillimeters"] = device.minimumFocusDistance
                configuredCapability["rawMainCameraFocusRecovery"] = false
                configuredCapability["continuousAutoFocusSupported"] = device.isFocusModeSupported(.continuousAutoFocus)
                configuredCapability["activeVideoStabilizationMode"] = video.connection(with: .video)?.activeVideoStabilizationMode.rawValue
                configuredCapability["configuredMinFrameDurationSeconds"] = actualMin
                configuredCapability["configuredMaxFrameDurationSeconds"] = actualMax
                configuredCapability["movieFileOutputAFTest"] = true
                configuredCapability["formatAppliedAfterSessionStart"] = liveRAWFormatSelection
                configuredCapability["codecConfiguredWithinFormatTransaction"] = liveRAWFormatSelection
                configuredCapability["preSessionFormatIndex"] = preSessionFormatIndex
                configuredCapability["preSessionDeviceConfigurationSkipped"] = rawAFMinimalComparison
                configuredCapability["rawAFMinimalGraph"] = rawAFMinimalComparison
                configuredCapability["rawAFWhiteBalanceLockedAfterSessionStart"] = false
                configuredCapability["rawAFWhiteBalanceLockMethod"] = rawAFMinimalComparison ? "none" : "gains"
                configuredCapability["explicitFaceDrivenAFOverride"] = false
                configuredCapability["explicitRAWStabilizationOverride"] = !avoidRAWStabilizationOverride
                configuredCapability["whiteBalanceMode"] = device.whiteBalanceMode.rawValue
                try JSONSerialization.data(withJSONObject: configuredCapability, options: [.prettyPrinted, .sortedKeys])
                    .write(to: root.appendingPathComponent("capture_capabilities_\(targetCodec.rawValue).json"))
                guard abs(actualMin - frameDuration.seconds) < 0.000001,
                      abs(actualMax - frameDuration.seconds) < 0.000001 else {
                    throw RecorderError.unavailable("Camera did not accept requested frame rate")
                }
                self.onExposureReading?(device.exposureDuration.seconds, device.iso)
                self.scheduleFocusPoll(device, token: self.focusPollToken)
                self.onState?(.ready, nil)
            } catch { self.onState?(.failed, error.localizedDescription) }
        }
    }

    private func recordFocusState(_ device: AVCaptureDevice, event: String) {
        func finite(_ value: Double) -> Any { value.isFinite ? value : NSNull() }
        let state: [String: Any] = ["hostSeconds": ProcessInfo.processInfo.systemUptime,
            "event": event, "camera": device.uniqueID, "codec": codec.rawValue,
            "mode": device.focusMode.rawValue, "adjusting": device.isAdjustingFocus,
            "lensPosition": finite(Double(device.lensPosition)), "system": device.activeFormat.autoFocusSystem.rawValue,
            "faceDriven": device.isFaceDrivenAutoFocusEnabled,
            "automaticFaceDriven": device.automaticallyAdjustsFaceDrivenAutoFocusEnabled,
            "smooth": device.isSmoothAutoFocusEnabled,
            "rangeRestriction": device.autoFocusRangeRestriction.rawValue,
            "exposureSeconds": finite(device.exposureDuration.seconds), "iso": finite(Double(device.iso))]
        var diagnosticState = state
        diagnosticState["focusPoint"] = [finite(Double(device.focusPointOfInterest.x)),
                                          finite(Double(device.focusPointOfInterest.y))]
        if #available(iOS 26.0, *) {
            diagnosticState["fullFrameFocusSupported"] = device.isFocusRectOfInterestSupported
            if device.isFocusRectOfInterestSupported {
                let rect = device.focusRectOfInterest
                diagnosticState["focusRect"] = [finite(Double(rect.origin.x)), finite(Double(rect.origin.y)),
                                                 finite(Double(rect.width)), finite(Double(rect.height))]
            }
        }
        let snapshot = diagnosticState
        focusDiagnosticsQueue.async {
            self.focusDiagnostics.append(snapshot)
            if self.focusDiagnostics.count > 240 { self.focusDiagnostics.removeFirst(self.focusDiagnostics.count - 240) }
            let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("GyroCineDiagnostics", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try JSONSerialization.data(withJSONObject: self.focusDiagnostics, options: [.sortedKeys])
                    .write(to: root.appendingPathComponent("focus_trace.json"), options: .atomic)
            } catch { NSLog("GyroCine focus diagnostics write failed: %@", error.localizedDescription) }
        }
    }

    private func scheduleFocusPoll(_ device: AVCaptureDevice, token: UUID) {
        sessionQueue.asyncAfter(deadline: .now() + .milliseconds(500)) { [weak self, weak device] in
            guard let self, let device, self.focusPollToken == token,
                  self.device === device, self.session.isRunning else { return }
            self.recordFocusState(device, event: "preview")
            self.onFocusReading?(device.lensPosition, device.focusMode, device.isAdjustingFocus)
            self.onExposureReading?(device.exposureDuration.seconds, device.iso)
            let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
            self.onWhiteBalanceReading?(wb.temperature, wb.tint)
            self.scheduleFocusPoll(device, token: token)
        }
    }

    /// Keep a RAW main-camera single-shot acquisition active until it finishes,
    /// then restore continuous AF. Tokens keep old timeouts off a new camera.
    private func reacquireRAWFocus(_ device: AVCaptureDevice, reason: String) {
        guard self.device === device, codec.isRAW, device.deviceType == .builtInWideAngleCamera,
              session.isRunning, focusRecoveryID == nil,
              device.isFocusModeSupported(.autoFocus),
              device.isFocusModeSupported(.continuousAutoFocus) else { return }
        let id = UUID()
        focusRecoveryID = id
        focusRecoverySawAdjustment = false
        focusAdjustmentObservation = device.observe(\.isAdjustingFocus, options: [.new]) { [weak self, weak device] _, change in
            guard let self, let device, let adjusting = change.newValue else { return }
            self.sessionQueue.async {
                guard self.device === device, self.focusRecoveryID == id else { return }
                self.recordFocusState(device, event: "adjusting-\(adjusting)")
                if adjusting { self.focusRecoverySawAdjustment = true }
                else if self.focusRecoverySawAdjustment {
                    self.finishRAWFocusRecovery(device, id: id, reason: "scan-ended")
                }
            }
        }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .none }
            if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = CGPoint(x: 0.5, y: 0.5) }
            device.focusMode = .autoFocus
            recordFocusState(device, event: "single-start-\(reason)")
            NSLog("GyroCine RAW AF start reason=%@ camera=%@ position=%.4f", reason, device.uniqueID, device.lensPosition)
        } catch {
            focusAdjustmentObservation = nil
            focusRecoveryID = nil
            NSLog("GyroCine RAW AF start failed: %@", error.localizedDescription)
            return
        }
        sessionQueue.asyncAfter(deadline: .now() + 3) { [weak self, weak device] in
            guard let self, let device else { return }
            self.finishRAWFocusRecovery(device, id: id, reason: "timeout")
        }
    }

    private func finishRAWFocusRecovery(_ device: AVCaptureDevice, id: UUID, reason: String) {
        guard self.device === device, focusRecoveryID == id else { return }
        focusAdjustmentObservation = nil
        focusRecoveryID = nil
        guard session.isRunning else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.focusMode = .continuousAutoFocus
            device.isSubjectAreaChangeMonitoringEnabled = true
            recordFocusState(device, event: "continuous-\(reason)")
            NSLog("GyroCine RAW AF continuous reason=%@ camera=%@ observedScan=%d position=%.4f", reason, device.uniqueID, focusRecoverySawAdjustment ? 1 : 0, device.lensPosition)
        } catch { NSLog("GyroCine RAW AF restore failed: %@", error.localizedDescription) }
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
        if captureMovieOutput != nil {
            sessionQueue.async { self.startMovieFile(at: url, externalDestination: externalDestination) }
            return
        }
        sampleQueue.async {
            do {
                self.recordingOrientation = orientation
                self.externalDestination = externalDestination
                guard let mode = self.mode else { throw RecorderError.unavailable("Camera not configured") }
                guard let connection = self.captureVideoOutput?.connection(with: .video),
                      connection.activeVideoStabilizationMode == .off else {
                    throw RecorderError.unavailable("相机视频防抖未关闭，请重新配置相机")
                }
                guard connection.videoRotationAngle == 0, !connection.isVideoMirrored else {
                    throw RecorderError.unavailable("录制连接方向异常，请重新配置相机")
                }
                var outputURL = url
                if self.codec.isRAW && externalDestination {
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
                if self.codec.isRAW && !externalDestination {
                    _ = RAWInternalStorage.enableProStorageIfSupported(on: writer)
                }
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
                          let codec = self.codec.avCodec else {
                        throw RecorderError.unavailable("当前录制位置没有可用的 ProRes RAW 编码设置，请检查专业视频存储设置或改用 SSD")
                    }
                    do {
                        outputSettings = try RAWSettingsProbe.settings(output: output, codec: codec, url: outputURL)
                    } catch {
                        if !externalDestination {
                            self.onInternalRAWSupport?(false, "当前模式无法在手机文件位置录制 RAW，请在设置中将录制位置切换为 SSD。系统信息：\(error.localizedDescription)")
                        }
                        throw error
                    }
                    let metadata = try RAWSettingsProbe.metadata(output: output, codec: codec)
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
                self.frameCopier = CaptureFrameCopier()
                self.pendingVideo = PendingVideoQueue<PendingFrame>(capacity: 48)
                self.peakPendingVideo = 0
                self.frameCount = 0
                self.droppedFrameCount = 0
                self.firstDroppedFrameReason = nil
                self.videoCallbackCount = 0
                self.writerNotReadyCallbacks = 0
                self.maxCallbackLagMs = 0
                self.maxFrameCopyMs = 0
                self.maxVideoDrainMs = 0
                self.maxSourceGapMs = 0
                self.previousSourcePTSSeconds = nil
                self.appendError = nil
                self.stopRequestLock.lock()
                self.stopRequested = false
                self.stopRequestLock.unlock()
                self.recordingActive = true
                self.onState?(.recording, nil)
            } catch {
                self.externalMovieURL?.stopAccessingSecurityScopedResource()
                self.externalMovieURL = nil
                self.onState?(.failed, error.localizedDescription)
            }
        }
    }

    private func startMovieFile(at url: URL, externalDestination: Bool) {
        do {
            guard let movie = captureMovieOutput, session.isRunning, !movie.isRecording,
                  let connection = movie.connection(with: .video),
                  connection.activeVideoStabilizationMode == .off else {
                throw RecorderError.unavailable("Movie output is not ready")
            }
            guard !codec.isRAW || externalDestination else {
                throw RecorderError.unavailable("RAW 对焦测试版录制需要外接 SSD；取景对焦无需录制")
            }
            var outputURL = url
            if codec.isRAW {
                guard AVExternalStorageDevice.authorizationStatus == .authorized,
                      let storage = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.first(where: { $0.isConnected }),
                      storage.freeSize >= 2_000_000_000,
                      let external = try storage.nextAvailableURLs(withPathExtensions: ["mov"]).first,
                      external.startAccessingSecurityScopedResource() else {
                    throw RecorderError.unavailable("ProRes RAW 需要已授权且至少有 2 GB 空间的外接 SSD")
                }
                outputURL = external
                externalMovieURL = external
            }
            guard !FileManager.default.fileExists(atPath: outputURL.path) else {
                throw RecorderError.unavailable("Movie output file already exists")
            }
            fileURL = url
            movie.startRecording(to: outputURL, recordingDelegate: self)
            onState?(.recording, nil)
        } catch {
            externalMovieURL?.stopAccessingSecurityScopedResource()
            externalMovieURL = nil
            onState?(.failed, error.localizedDescription)
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    startPTS: CMTime, from connections: [AVCaptureConnection]) {
        sessionQueue.async {
            let hostPTS = try? ClockAligner.hostTime(startPTS, clock: self.session.synchronizationClock)
            DiagnosticsCollector.record("MovieFileOutput startPTS=\(startPTS.seconds) hostPTS=\(String(describing: hostPTS))",
                                        folder: self.fileURL?.deletingLastPathComponent())
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL,
                    from connections: [AVCaptureConnection], error: Error?) {
        sessionQueue.async {
            guard let url = self.fileURL else { return }
            var failure = error?.localizedDescription
            if failure == nil, let external = self.externalMovieURL {
                do { try FileManager.default.moveItem(at: external, to: url) }
                catch { failure = "RAW 已保存在 SSD，归档失败: \(error.localizedDescription)" }
            }
            self.onCaptureFinished?()
            self.onMovieFileCompleted?(url, failure)
            self.fileURL = nil
        }
    }

    func releaseExternalMovieAccess() {
        sampleQueue.async {
            self.externalMovieURL?.stopAccessingSecurityScopedResource()
            self.externalMovieURL = nil
        }
    }

    func stop() {
        if captureMovieOutput != nil {
            sessionQueue.async {
                guard let movie = self.captureMovieOutput, movie.isRecording else { return }
                self.onState?(.finalizing, nil)
                movie.stopRecording()
            }
            return
        }
        // The UI can request STOP while capture callbacks already fill sampleQueue.
        // Prevent those callbacks from copying more full-resolution frames.
        stopRequestLock.lock()
        stopRequested = true
        stopRequestLock.unlock()
        sampleQueue.async {
            guard self.recordingActive, self.writer != nil, let url = self.fileURL else { return }
            self.recordingActive = false
            DiagnosticsCollector.record("buffer=\(self.frameCopier.capacityDescription) capture dropped callbacks=\(self.droppedFrameCount) firstReason=\(self.firstDroppedFrameReason ?? "none")", folder: url.deletingLastPathComponent())
            self.recordPipelineMetrics(folder: url.deletingLastPathComponent())
            self.onState?(.finalizing, nil)
            if let writer = self.writer, writer.status == .writing {
                self.completeStopWhenDrained(deadline: ProcessInfo.processInfo.systemUptime + 5)
            } else {
                self.finishFailedWriter(url: url)
            }
        }
    }

    private func drainPendingVideo() throws {
        guard let input = videoInput else { return }
        try pendingVideo.drain(ready: { input.isReadyForMoreMediaData }) { frame in
            guard input.append(frame.sample) else {
                throw writer?.error ?? RecorderError.unavailable("Video append failed")
            }
            frameCount += 1
            lastPTS = frame.pts
            try frameEvidenceHandle?.write(contentsOf: evidenceEncoder.encode(frame.evidence) + Data([0x0A]))
        }
    }

    private func recordPipelineMetrics(folder: URL) {
        DiagnosticsCollector.record(String(format:
            "pipeline callbacks=%d written=%d pending=%d peakPending=%d writerNotReady=%d maxCallbackLagMs=%.2f maxCopyMs=%.2f maxDrainMs=%.2f maxSourceGapMs=%.2f footprintMB=%.1f sourceFormatChanges=%d copiedFormatChanges=%d %@",
            videoCallbackCount, frameCount, pendingVideo.count, peakPendingVideo, writerNotReadyCallbacks,
            maxCallbackLagMs, maxFrameCopyMs, maxVideoDrainMs, maxSourceGapMs,
            physicalFootprintMB(), frameCopier.sourceFormatChanges, frameCopier.copiedFormatChanges,
            frameCopier.capacityDescription), folder: folder)
    }

    private func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_000_000 : -1
    }

    private func finishFailedWriter(url: URL) {
        let writerError = writer?.error?.localizedDescription ?? "Video writer stopped before completion"
        let error = appendError ?? writerError
        pendingVideo.removeAll()
        do {
            try frameEvidenceHandle?.close()
            try frameEvidenceHandle?.publish()
        } catch {
            DiagnosticsCollector.record("failed writer evidence publish error=\(error.localizedDescription)", folder: url.deletingLastPathComponent())
        }
        frameEvidenceHandle = nil
        DiagnosticsCollector.record("writer failed reason=\(error)", folder: url.deletingLastPathComponent())
        onCaptureFinished?()
        let clock = clockEvidence
        let frames = frameCount
        frameCopier = CaptureFrameCopier()
        writer = nil
        videoInput = nil
        audioInput = nil
        onCompleted?(url, clock, frames, error)
    }

    private func completeStopWhenDrained(deadline: Double) {
        guard let writer, let url = fileURL else { return }
        guard writer.status == .writing else { finishFailedWriter(url: url); return }
        do { try drainPendingVideo() }
        catch { appendError = appendError ?? error.localizedDescription; pendingVideo.removeAll() }
        guard writer.status == .writing else { finishFailedWriter(url: url); return }
        if pendingVideo.count > 0 {
            if writer.status == .writing && ProcessInfo.processInfo.systemUptime < deadline {
                sampleQueue.asyncAfter(deadline: .now() + .milliseconds(10)) {
                    self.completeStopWhenDrained(deadline: deadline)
                }
                return
            }
            appendError = appendError ?? "停止后视频队列仍未排空（\(pendingVideo.count) 帧），原片已保留"
            pendingVideo.removeAll()
        }
        DiagnosticsCollector.record("video queue drained peak=\(peakPendingVideo)", folder: url.deletingLastPathComponent())
            do {
                try self.frameEvidenceHandle?.close()
            } catch { self.appendError = "Video timing evidence close failed: \(error.localizedDescription)" }
            let evidenceLog = self.frameEvidenceHandle
            self.frameEvidenceHandle = nil
            self.videoInput?.markAsFinished()
            self.audioInput?.markAsFinished()
            let finishStarted = ProcessInfo.processInfo.systemUptime
            writer.finishWriting {
                DiagnosticsCollector.record(String(format: "writer finished elapsed=%.3fs status=%d",
                    ProcessInfo.processInfo.systemUptime - finishStarted, writer.status.rawValue), folder: url.deletingLastPathComponent())
                self.onCaptureFinished?()
                var error = self.appendError ?? writer.error?.localizedDescription
                if writer.status != .completed {
                    error = error ?? "Video writer did not complete (status=\(writer.status.rawValue))"
                }
                do { try evidenceLog?.publish() }
                catch let logError { error = error ?? logError.localizedDescription }
                if let external = self.externalMovieURL {
                    // The RAW file retains its system-granted access through metadata finalization.
                    // Moving it into an authorized directory must not shorten that lease.
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
                DiagnosticsCollector.record(String(format: "writer archive/log publish finished elapsed=%.3fs",
                    ProcessInfo.processInfo.systemUptime - finishStarted), folder: url.deletingLastPathComponent())
                self.sampleQueue.async {
                    let clock = self.clockEvidence
                    let frames = self.frameCount
                    self.pendingVideo.removeAll()
                    self.frameCopier = CaptureFrameCopier()
                    self.writer = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.onCompleted?(url, clock, frames, error)
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
                recordFocusState(device, event: "preview")
                onExposureReading?(device.exposureDuration.seconds, device.iso)
                let wb = device.temperatureAndTintValues(for: device.deviceWhiteBalanceGains)
                onWhiteBalanceReading?(wb.temperature, wb.tint)
            }
        }
        stopRequestLock.lock()
        let stopping = stopRequested
        stopRequestLock.unlock()
        guard recordingActive, !stopping, let writer else { return }
        guard writer.status == .writing else {
            appendError = appendError ?? writer.error?.localizedDescription ?? "Video writer stopped before completion"
            stop()
            return
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if output is AVCaptureVideoDataOutput {
            guard connection.videoRotationAngle == 0, !connection.isVideoMirrored,
                  let image = CMSampleBufferGetImageBuffer(sampleBuffer), let mode,
                  CVPixelBufferGetWidth(image) == mode.width, CVPixelBufferGetHeight(image) == mode.height else {
                appendError = "录制帧方向或尺寸发生变化，原始数据已保留"
                stop()
                return
            }
            let hostPTS: Double
            do { hostPTS = try ClockAligner.hostTime(pts, clock: session.synchronizationClock) }
            catch {
                appendError = error.localizedDescription
                stop()
                return
            }
            videoCallbackCount += 1
            let sourcePTSSeconds = CMTimeGetSeconds(pts)
            if let previousSourcePTSSeconds {
                maxSourceGapMs = max(maxSourceGapMs, (sourcePTSSeconds - previousSourcePTSSeconds) * 1000)
            }
            previousSourcePTSSeconds = sourcePTSSeconds
            let callbackHostSeconds = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            maxCallbackLagMs = max(maxCallbackLagMs, (callbackHostSeconds - hostPTS) * 1000)
            if firstPTS == nil {
                firstPTS = pts
                clockEvidence = ClockAligner.evidence(firstPTS: pts, hostPTS: hostPTS,
                    callbackHostTime: callbackHostSeconds)
                writer.startSession(atSourceTime: pts)
            }
            let encoderSample: CMSampleBuffer
            let copyStarted = ProcessInfo.processInfo.systemUptime
            do { encoderSample = try frameCopier.copy(sampleBuffer) }
            catch { appendError = error.localizedDescription; stop(); return }
            maxFrameCopyMs = max(maxFrameCopyMs, (ProcessInfo.processInfo.systemUptime - copyStarted) * 1000)
                let evidence = CaptureFrameEvidence(hostPTSSeconds: hostPTS, sourcePTSSeconds: CMTimeGetSeconds(pts),
                    cameraIntrinsicMatrix: CaptureFrameEvidence.intrinsicMatrix(sampleBuffer),
                    intrinsicSource: "kCMSampleBufferAttachmentKey_CameraIntrinsicMatrix; native unrotated output buffer coordinates",
                    activeVideoStabilizationMode: connection.activeVideoStabilizationMode.rawValue,
                    deviceExposureDurationAtCallbackSeconds: device?.exposureDuration.seconds,
                    deviceISOAtCallback: device?.iso,
                    deviceFocusModeAtCallback: device?.focusMode.rawValue,
                    deviceLensPositionAtCallback: device?.lensPosition,
                    deviceIsAdjustingFocusAtCallback: device?.isAdjustingFocus)
            do {
                if videoInput?.isReadyForMoreMediaData == false { writerNotReadyCallbacks += 1 }
                try pendingVideo.enqueue(PendingFrame(sample: encoderSample, pts: pts, evidence: evidence))
                peakPendingVideo = max(peakPendingVideo, pendingVideo.count)
                let drainStarted = ProcessInfo.processInfo.systemUptime
                try drainPendingVideo()
                maxVideoDrainMs = max(maxVideoDrainMs, (ProcessInfo.processInfo.systemUptime - drainStarted) * 1000)
                if videoCallbackCount == 1 || videoCallbackCount.isMultiple(of: 60), let fileURL {
                    recordPipelineMetrics(folder: fileURL.deletingLastPathComponent())
                }
            } catch { appendError = error.localizedDescription; stop() }
        } else if firstPTS != nil, let audioInput, audioInput.isReadyForMoreMediaData {
            if !audioInput.append(sampleBuffer) {
                appendError = writer.error?.localizedDescription ?? "Audio append failed"
                stop()
            }
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
