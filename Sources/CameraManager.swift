import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox

enum WhiteBalanceChoice: String, CaseIterable { case autoLock = "Auto-L", auto = "Auto", manual = "Manual" }

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published var showingProLimit = false
    @Published private(set) var ssdSpeedTesting = false
    @Published private(set) var ssdSpeedProgress = 0.0
    @Published private(set) var ssdSpeedCurrentMBps = 0.0
    @Published private(set) var ssdSpeedReport: SSDSpeedReport?
    @Published private(set) var ssdSpeedError: String?
    @Published private(set) var ssdSpeedSpecifications: [SSDSpeedSpecification] = []
    private var ssdSpeedCancellation: SSDSpeedCancellation?
    func refreshSSDSpeedAssessment() {
        queue.async {
            guard self.ssdSpeedCancellation == nil else { return }
            let specifications = self.makeSSDSpeedSpecifications()
            self.publish { self.ssdSpeedSpecifications = specifications }
            let size = self.device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
            let config = "\(self.chosenEncoding.title) · \(size?.width ?? 0)×\(size?.height ?? 0) · \(String(format: "%.1f", self.chosenFPS)) fps"
            let required = self.estimatedBytesPerSecond / 1_000_000
            let fps = self.chosenFPS
            let bufferLimit: Int? = self.usesRAWWriterExperiment ? 10 : nil
            let drives = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
            let selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
            let drive = drives.first(where: { $0.uuid?.uuidString == selectedID }) ?? (drives.count == 1 ? drives.first : nil)
            self.publish {
                guard var report = self.ssdSpeedReport else { return }
                guard let id = drive?.uuid?.uuidString, id == report.driveID else { self.ssdSpeedReport = nil; return }
                report.configuration = config; report.requiredMBps = required; report.fps = fps; report.bufferedFrameLimit = bufferLimit
                self.ssdSpeedReport = report
            }
        }
    }
    // Enumerate cached capabilities; never reconfigure the capture session for this guide.
    private func makeSSDSpeedSpecifications() -> [SSDSpeedSpecification] {
        var result: [SSDSpeedSpecification] = []
        for encoding in VideoEncoding.allCases {
            let compatible = formatObjects.filter { $0.compatibleCodecs.contains(encoding.codec.rawValue) && $0.width >= 1920 }
            let groups = Dictionary(grouping: compatible) { "\($0.width)×\($0.height)" }
            for (_, formats) in groups {
                guard let format = formats.first else { continue }
                let rates = Set(formats.flatMap { availableFPS(for: $0) }).sorted()
                for rate in rates {
                    let key = "recordingBitrate.v1.\(Self.hardwareModel()).\(device?.uniqueID ?? "unknown").\(encoding.rawValue).\(format.width)x\(format.height).\(rate)" +
                        (encoding == .hevc ? ".\(chosenHEVCBitratePreset.rawValue)" : "")
                    let learned = UserDefaults.standard.double(forKey: key)
                    let bits = encoding.estimatedBitsPerPixelPerFrame
                    let fallback = (encoding == .hevc ? chosenHEVCBitratePreset.targetBitsPerSecond(
                        width: format.width, height: format.height, fps: rate) : nil)
                        .map { Double($0) / 8 * 1.25 + 100_000 }
                        ?? max(1_000_000, Double(format.width) * Double(format.height) * rate * bits / 8 + 100_000)
                    let validLearned = learned.isFinite && learned > 0
                    let assessmentRate = max(validLearned ? learned : fallback, fallback * 0.25)
                    result.append(SSDSpeedSpecification(encoding: encoding, width: format.width, height: format.height,
                        fps: rate, requiredMBps: assessmentRate / 1_000_000,
                        learned: validLearned))
                }
            }
        }
        return result.sorted {
            if $0.width != $1.width { return $0.width > $1.width }
            if $0.height != $1.height { return $0.height > $1.height }
            return $0.fps > $1.fps
        }
    }
    func cancelSSDSpeedTest() { queue.async { self.ssdSpeedCancellation?.cancel() } }
    func startSSDSpeedTest() {
        queue.async {
            guard self.ssdSpeedCancellation == nil, !self.captureFinishing, !self.recordingStarting,
                  !self.output.isRecording, self.rawWriterExperiment == nil, self.canFinalizeNow else {
                self.publish { self.ssdSpeedError = "请等待录制或保存完成 / Wait for recording or saving to finish" }; return
            }
            let drives = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
            let selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
            guard let drive = drives.first(where: { $0.uuid?.uuidString == selectedID }) ?? (drives.count == 1 ? drives.first : nil) else {
                self.publish { self.ssdSpeedError = "请连接并选择 SSD / Connect and select an SSD" }; return
            }
            guard drive.freeSize >= SSDSpeedTest.bytes + 5_000_000_000 else {
                self.publish { self.ssdSpeedError = "测速需要至少 14 GB 可用空间 / At least 14 GB free is required" }; return
            }
            do {
                guard let url = try drive.nextAvailableURLs(withPathExtensions: ["tmp"]).first,
                      url.startAccessingSecurityScopedResource() else { throw RecorderError.unavailable("无法访问 SSD / Cannot access SSD") }
                let token = SSDSpeedCancellation()
                self.ssdSpeedCancellation = token
                self.captureFinishing = true
                let driveName = drive.displayName ?? "SSD"
                let driveID = drive.uuid?.uuidString
                let size = self.device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
                let config = "\(self.chosenEncoding.title) · \(size?.width ?? 0)×\(size?.height ?? 0) · \(String(format: "%.1f", self.chosenFPS)) fps"
                let required = self.estimatedBytesPerSecond / 1_000_000
                let fps = self.chosenFPS
                let bufferLimit: Int? = self.usesRAWWriterExperiment ? 10 : nil
                self.publish { self.ssdSpeedTesting = true; self.ssdSpeedProgress = 0; self.ssdSpeedCurrentMBps = 0; self.ssdSpeedReport = nil; self.ssdSpeedError = nil }
                self.logger.event("ssd_speed_ui_started", ["drive": driveName, "configuration": config, "requiredMBps": required, "path": url.path])
                DispatchQueue.global(qos: .utility).async {
                    let result = Result { try SSDSpeedTest.run(url: url, cancellation: token) { progress, rate in
                        self.publish { self.ssdSpeedProgress = progress; self.ssdSpeedCurrentMBps = rate }
                    } }
                    url.stopAccessingSecurityScopedResource()
                    self.queue.async {
                        self.ssdSpeedCancellation = nil; self.captureFinishing = false
                        self.publish {
                            self.ssdSpeedTesting = false
                            switch result {
                            case .success(let value):
                                let report = SSDSpeedReport(drive: driveName, driveID: driveID, configuration: config, requiredMBps: required, fps: fps, bufferedFrameLimit: bufferLimit,
                                    averageMBps: value.average, sustainedMBps: value.sustained, maximumWriteMS: value.maxWriteMS, maximumFlushMS: value.maxFlushMS)
                                self.ssdSpeedReport = report
                                self.logger.event("ssd_speed_ui_completed", ["sustainedMBps": value.sustained, "averageMBps": value.average,
                                    "maxWriteMS": value.maxWriteMS, "assessment": String(describing: report.assessment), "temporaryFileRemoved": true])
                            case .failure(let error):
                                self.ssdSpeedError = error is CancellationError ? "测速已取消，临时文件已清理 / Cancelled; test file removed" : error.localizedDescription
                                self.logger.event("ssd_speed_ui_failed", ["error": error.localizedDescription])
                            }
                        }
                    }
                }
            } catch { self.publish { self.ssdSpeedError = error.localizedDescription } }
        }
    }

    @Published private(set) var formats: [FormatInfo] = []
    @Published private(set) var codecs: [AVVideoCodecType] = []
    @Published private(set) var selectedCodec: AVVideoCodecType?
    @Published private(set) var selectedEncoding: VideoEncoding = .hevc
    @Published private(set) var selectedRecordingColorSpace: RecordingColorSpace = .rec709
    @Published private(set) var hevcBitratePreset = HEVCBitratePreset.stored(
        UserDefaults.standard.string(forKey: "hevcBitratePreset"))
    @Published private(set) var selectedFormatIndex: Int?
    @Published private(set) var fps: Double = 60
    @Published private(set) var focusChoice: FocusChoice = .continuous
    @Published private(set) var adjusting = false
    @Published private(set) var lensPosition: Float = 0
    @Published private(set) var actualFocusMode = "Unknown"
    @Published private(set) var recording = false
    @Published private(set) var status = "Requesting camera permission"
    @Published private(set) var errorText: String?
    @Published private(set) var storageSetupRequired = false
    @Published private(set) var availableStorageBytes: Int64?
    @Published private(set) var checkedStorageLocation: String?
    @Published private(set) var estimatedRecordingSeconds: Double?
    private var storageStopRequested = false
    @Published private(set) var exportURL: URL?
    @Published private(set) var lenses: [LensChoice] = []
    @Published private(set) var selectedLensID: String?
    @Published private(set) var switchingLens = false
    @Published private(set) var audioAvailable = false
    @Published private(set) var imuAvailable = false
    @Published private(set) var telemetryEmbeddable = true
    @Published private(set) var externalStorageConnected = false
    @Published private(set) var cameraReady = false
    @Published private(set) var finalizing = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var exposureSeconds: Double = 1.0 / 60.0
    @Published private(set) var iso: Float = 100
    @Published private(set) var whiteBalanceKelvin: Float = 5600
    @Published private(set) var exposureAuto = true
    @Published private(set) var shutterMode: ShutterMode = .autoMax
    @Published private(set) var shutterMaxSeconds: Double = 1.0 / 60.0
    @Published private(set) var shutterAngle: Double = 180
    @Published private(set) var whiteBalanceAuto = true
    @Published private(set) var whiteBalanceChoice: WhiteBalanceChoice = .autoLock
    @Published private(set) var exposureBias: Double = 0
    @Published private(set) var exposureBiasRange: ClosedRange<Double> = -6...6
    private var chosenWhiteBalance: WhiteBalanceChoice = .auto
    private var manualWhiteBalanceKelvin: Float?
    private var autoLockWhiteBalanceActive = false
    private var exposureBiasIntent: Double = 0
    @Published private(set) var isoRange: ClosedRange<Double> = 50...3200
    @Published private(set) var exposureRange: ClosedRange<Double> = 1.0 / 1000.0...1.0 / 30.0

    @Published private(set) var lutEnabled = UserDefaults.standard.bool(forKey: "previewLUTEnabled")
    @Published private(set) var lutLook = PreviewLook(rawValue: UserDefaults.standard.string(forKey: "previewLUTLook") ?? "") ?? .rec709
    @Published private(set) var lutSupported = false
    @Published private(set) var lutStatus = "off"
    @Published private(set) var importedLUTs = PreviewLUTLibrary.load()
    @Published private(set) var importedLUTID = UserDefaults.standard.string(forKey: "previewImportedLUTID")
    @Published private(set) var importingLUT = false
    private let lutImportQueue = DispatchQueue(label: "GyroCine.LUTImport", qos: .userInitiated)
    var selectedImportedLUT: ImportedPreviewLUT? { importedLUTs.first { $0.selectionID == importedLUTID } }
    var selectedLUTID: String { selectedImportedLUT?.selectionID ?? lutLook.rawValue }
    var selectedLUTTitle: String { selectedImportedLUT?.name ?? lutLook.title }
    @Published private(set) var lutBurnEnabled = UserDefaults.standard.bool(forKey: "lutBurnEnabled")
    @Published private(set) var disabledLUTIDs = Set(UserDefaults.standard.stringArray(forKey: "disabledLUTIDs") ?? [])
    var visibleBuiltinLUTs: [PreviewLook] { PreviewLook.allCases.filter { !disabledLUTIDs.contains($0.rawValue) } }
    var visibleImportedLUTs: [ImportedPreviewLUT] { importedLUTs.filter { !disabledLUTIDs.contains($0.selectionID) } }
    var lutControlsLocked: Bool { recording || preparingRecording || finalizing }
    func setLUTBurnEnabled(_ value: Bool) {
        guard !lutControlsLocked else { return }
        if value, disabledLUTIDs.contains(selectedLUTID) {
            if let look = visibleBuiltinLUTs.first { setLUTLook(look) }
            else if let item = visibleImportedLUTs.first { selectImportedLUT(item) }
            else { return }
        }
        lutBurnEnabled = value && !selectedEncoding.isRAW
        UserDefaults.standard.set(lutBurnEnabled, forKey: "lutBurnEnabled")
        if lutBurnEnabled { setLUTEnabled(true) }
    }
    func setLUTVisible(_ item: ImportedPreviewLUT, enabled: Bool) {
        setLUTVisible(id: item.selectionID, enabled: enabled)
    }
    func setLUTVisible(_ look: PreviewLook, enabled: Bool) {
        setLUTVisible(id: look.rawValue, enabled: enabled)
    }
    private func setLUTVisible(id: String, enabled: Bool) {
        guard !lutControlsLocked else { return }
        if enabled { disabledLUTIDs.remove(id) } else { disabledLUTIDs.insert(id) }
        UserDefaults.standard.set(Array(disabledLUTIDs), forKey: "disabledLUTIDs")
        if !enabled, selectedLUTID == id { setLUTEnabled(false) }
    }
    let lutPreview = LUTPreview()
    func setLUTEnabled(_ enabled: Bool) {
        guard !enabled || !disabledLUTIDs.contains(selectedLUTID) else { return }
        guard lutEnabled != enabled else { return }
        lutEnabled = enabled
        if !enabled { lutBurnEnabled = false; UserDefaults.standard.set(false, forKey: "lutBurnEnabled") }
        UserDefaults.standard.set(enabled, forKey: "previewLUTEnabled")
        lutPreview.setEnabled(enabled)
        logger.event("lut_preview_toggle", ["enabled": enabled, "previewOnly": true])
    }
    func setLUTLook(_ look: PreviewLook) {
        guard !disabledLUTIDs.contains(look.rawValue) else { return }
        if lutLook != look || importedLUTID != nil {
            importedLUTID = nil
            UserDefaults.standard.removeObject(forKey: "previewImportedLUTID")
            lutLook = look
            UserDefaults.standard.set(look.rawValue, forKey: "previewLUTLook")
            lutPreview.setLook(look)
            logger.event("lut_preview_look", ["look": look.rawValue, "previewOnly": true])
        }
        setLUTEnabled(true)
    }
    func selectImportedLUT(_ item: ImportedPreviewLUT) {
        guard !disabledLUTIDs.contains(item.selectionID) else { return }
        importedLUTID = item.selectionID
        UserDefaults.standard.set(item.selectionID, forKey: "previewImportedLUTID")
        lutPreview.setImportedLook(item)
        setLUTEnabled(true)
    }
    func importPreviewLUT(_ url: URL) {
        importingLUT = true
        lutImportQueue.async {
            do {
                let item = try PreviewLUTLibrary.importFile(url)
                let items = PreviewLUTLibrary.load()
                self.publish {
                    self.importedLUTs = items; self.importingLUT = false
                    self.selectImportedLUT(item)
                }
            } catch {
                self.publish { self.importingLUT = false; self.errorText = error.localizedDescription }
            }
        }
    }
    func reportLUTImportError(_ error: Error) { errorText = error.localizedDescription }
    func deleteImportedLUT(_ item: ImportedPreviewLUT) {
        lutImportQueue.async {
            do {
                try PreviewLUTLibrary.remove(item)
                let items = PreviewLUTLibrary.load()
                self.publish {
                    self.importedLUTs = items
                    if self.importedLUTID == item.selectionID { self.setLUTLook(.rec709) }
                }
            } catch { self.publish { self.errorText = error.localizedDescription } }
        }
    }
    // Camera queue only. Add the small ISP proxy before recording, so UI toggles never reconfigure capture.
    private func configureLUTPreview() {
        lutPreview.log = { [weak self] name, details in self?.logger.event(name, details) }
        lutPreview.statusChanged = { [weak self] status in self?.lutStatus = status }
        let shared = !chosenEncoding.isRAW && session.outputs.contains(intrinsicOutput)
        if shared, session.outputs.contains(lutPreview.output) { session.removeOutput(lutPreview.output) }
        lutPreview.setSharedSource(shared)
        guard lutPreview.metalDevice != nil,
              shared || session.outputs.contains(lutPreview.output) || session.canAddOutput(lutPreview.output) else {
            publish { self.lutSupported = false; self.lutStatus = "unavailable" }; return
        }
        if !shared, !session.outputs.contains(lutPreview.output) { session.addOutput(lutPreview.output) }
        lutPreview.configure(fps: chosenFPS)
        lutPreview.setLook(PreviewLook(rawValue: UserDefaults.standard.string(forKey: "previewLUTLook") ?? "") ?? .rec709)
        if let selected = PreviewLUTLibrary.load().first(where: {
            $0.selectionID == UserDefaults.standard.string(forKey: "previewImportedLUTID")
        }) { lutPreview.setImportedLook(selected) }
        lutPreview.setEnabled(UserDefaults.standard.bool(forKey: "previewLUTEnabled"))
        publish { self.lutSupported = true }
    }
    let session = AVCaptureSession()
    let logger = DiagnosticLogger()
    private let queue = DispatchQueue(label: "RAWFocusTest.camera", qos: .userInitiated)
    private let finalizationQueue = DispatchQueue(label: "GyroCine.finalization", qos: .utility)
    private var startRequested = false
    private var captureConfigured = false
    private var finalizationAllowed = false // Camera queue; updated from main-thread lifecycle snapshots.
    private var recoveryInProgress = false
    #if DEBUG
    private var responsivenessTimer: DispatchSourceTimer?
    #endif
    private let gravityMonitor = GravityOrientationMonitor()
    private var recordingOrientation: RecordingOrientation = .portrait
    private let output = AVCaptureMovieFileOutput()
    private let intrinsicOutput = AVCaptureVideoDataOutput()
    private let intrinsicRecorder = CameraIntrinsicsRecorder()
    private lazy var previewFanout = IntrinsicsPreviewFanout(recorder: intrinsicRecorder, preview: lutPreview)
    #if DEBUG
    private let captureStartProbe = CaptureStartTimestampProbe()
    #endif
    private var intrinsicURL: URL?
    private var intrinsicsUnavailableReason: String?
    private var device: AVCaptureDevice?
    private var formatObjects: [FormatInfo] = []
    private var supportedCodecs: [AVVideoCodecType] = []
    private var chosenCodec: AVVideoCodecType?
    private var chosenEncoding: VideoEncoding = .hevc
    private var chosenRecordingColorSpace: RecordingColorSpace = .rec709
    private var chosenHEVCBitratePreset = HEVCBitratePreset.stored(
        UserDefaults.standard.string(forKey: "hevcBitratePreset"))
    private var chosenIndex: Int?
    private var chosenFPS: Double = 60
    private var shutterMaxCustomized = false
    private var activeShutterAngle: Double?
    private var manualExposureIntent: ManualExposurePreference?
    private var savedControls = SavedCameraControls()
    private var chosenFocus: FocusChoice = .continuous
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private struct CapturePreference {
        let encoding: VideoEncoding
        let width: Int32
        let height: Int32
        let fps: Double
    }
    private struct ManualExposurePreference {
        let seconds: Double
        let iso: Double
        let angle: Double?
    }
    private func manualExposurePreference(_ camera: AVCaptureDevice) -> ManualExposurePreference? {
        if let manualExposureIntent { return manualExposureIntent }
        guard camera.exposureMode == .custom else { return nil }
        return ManualExposurePreference(seconds: camera.exposureDuration.seconds,
                                        iso: Double(camera.iso), angle: activeShutterAngle)
    }
    private var observations: [NSKeyValueObservation] = []
    private var sampleTimer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var currentFile: URL?
    private var activeExternalMovieURL: URL?
    private var activeExternalMovieBookmark: Data?
    private var restoreAutoWhiteBalanceAfterRecording = false
    private var rawPreparedSignature: String?
    private var rawPipelineReadyAt: Double = 0
    private var rawStartWaiting = false
    private var externalStorageObservation: NSKeyValueObservation?
    private var clearStorageErrorOnReconnect = false
    @Published private(set) var preparingRecording = false
    private var recordingStarting = false {
        didSet { let value = recordingStarting; publish { self.preparingRecording = value } }
    }
    private var imuRecorder: IMURecorder?
    private var pendingRecordingJob: PendingIMUJob?
    private var recordingSetupFailure: String?
    private var recordingCadenceWarning: String?
    private var backgroundLease: UIBackgroundTaskIdentifier = .invalid // Main thread only.
    private var attemptedPendingJobs = Set<String>()
    private var failedPendingSignatures: [String: String] = [:]
    private var captureFinishing = false // Camera queue only.
    private var storageReplenishPending = true
    private var storageReplenishFromDeletion = false
    private var storageReplenishRetries = 0
    private var storageReplenishNotBefore: Double = 0
    private var movieFirstFrameHost: Double?
    private var recordingTimeSource: String?
    private var nativeRAWKSupport: [String: Bool] = [:]
    private var nativeRAWKKey: String { "\(device?.uniqueID ?? ""):\(chosenIndex ?? -1)" }
    private var currentTelemetrySupport: Bool {
        if usesRAWWriterExperiment { return nativeRAWKSupport[nativeRAWKKey] ?? false }
        return intrinsicOutput.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled ?? false
    }
    private var usesRAWWriterExperiment: Bool {
        if #available(iOS 27.0, *) {
            // The preview pipeline depends on the codec, not the destination.
            // Ordinary internal storage must not fall back to MovieFileOutput at RAW 120 fps.
            return ["aprn", "aprh"].contains(chosenCodec?.rawValue ?? "")
        }
        return false
    }
    private var isRAWWriterActive: Bool { rawWriterExperiment != nil }
    private var recordingLens = ""
    private var realtimeLUTVideoSettings: [String: Any]?
    private var realtimeLUTWriter: RealtimeLUTWriter?
    private var recordingLUTBurn: LUTBurnRecipe?
    private var audioReady = false
    private var telemetryReadoutTick = 0
    #if DEBUG
    private let verificationQueue = DispatchQueue(label: "GyroCine.testVerification", qos: .utility)
    private var rawSmokeMovieName: String?
    private var rawWriterSmokeCompleted = 0
    private var exposureSmokeLensSwitchAttempted = false
    #endif
    private var rawWriterExperiment: AnyObject?
    private var rawWriterPreview: AnyObject?
    private var rawWriterStartRequested = false

    override init() {
        super.init()
        CaptureDefaults.restoreIfNeeded()
        savedControls = SavedCameraControls.load()
        chosenWhiteBalance = WhiteBalanceChoice(rawValue: savedControls.whiteBalance) ?? .autoLock
        manualWhiteBalanceKelvin = savedControls.kelvin
        exposureBiasIntent = savedControls.ev
        if savedControls.shutter == "manual" || savedControls.shutter == "angle" {
            manualExposureIntent = ManualExposurePreference(seconds: savedControls.seconds, iso: savedControls.iso,
                angle: savedControls.shutter == "angle" ? savedControls.angle : nil)
        }
        if !UserDefaults.standard.bool(forKey: "rulerHapticsDefaultEnabledV1") {
            UserDefaults.standard.set(true, forKey: "rulerHaptics")
            UserDefaults.standard.set(true, forKey: "rulerHapticsDefaultEnabledV1")
        }
        UserDefaults.standard.register(defaults: ["storageLocation": "内部文件", "exposureType": "angle"])
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--cleanup-uitest-media") {
            do {
                let files = try FileManager.default.contentsOfDirectory(at: RecordingStoragePaths.movieDirectory,
                    includingPropertiesForKeys: [.fileSizeKey]).filter {
                        $0.lastPathComponent.hasPrefix("UITEST_") && $0.pathExtension.lowercased() == "mov"
                    }
                var bytes = 0
                for file in files {
                    let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    try Self.removeMediaFiles(file)
                    bytes += size
                    logger.event("uitest_media_deleted", ["file": file.lastPathComponent, "bytes": size])
                }
                logger.event("uitest_cleanup_complete", ["files": files.count, "bytes": bytes])
                if #available(iOS 27.0, *), let storage = AVProVideoStorage.shared, storage.busyReasons.isEmpty {
                    storage.replenishCapacity { capacity, error in
                        self.logger.event("storage_replenished", ["remainingBytes": capacity,
                            "error": error?.localizedDescription ?? ""])
                    }
                }
            } catch { logger.event("uitest_cleanup_failed", ["error": error.localizedDescription]) }
        }
        if ProcessInfo.processInfo.arguments.contains("--raw-writer-integrated-experiment") {
            UserDefaults.standard.set(true, forKey: "debug.rawInternalWriterExperiment")
        }
        if ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") {
            UserDefaults.standard.set("内部文件", forKey: "storageLocation")
            UserDefaults.standard.set("SonyMov", forKey: "outputFormat")
        }
        if ProcessInfo.processInfo.arguments.contains("--exposure-proto-probe") {
            UserDefaults.standard.set("GyroflowProto", forKey: "outputFormat")
        }
        #endif
        gravityMonitor.start()
        logger.event("app_launch", ["model": Self.hardwareModel(), "systemName": UIDevice.current.systemName,
                                    "systemVersion": UIDevice.current.systemVersion])
        observeSessionEvents()
        if let discovery = AVExternalStorageDeviceDiscoverySession.shared {
            externalStorageObservation = discovery.observe(\.externalStorageDevices, options: [.initial, .new]) { [weak self] _, _ in
                guard let self else { return }
                self.queue.async {
                    let available = discovery.externalStorageDevices.filter(\.isConnected)
                    var selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
                    if !available.contains(where: { $0.uuid?.uuidString == selectedID }),
                       available.count == 1, let replacement = available.first?.uuid?.uuidString {
                        selectedID = replacement
                        UserDefaults.standard.set(replacement, forKey: "externalDeviceID")
                        self.logger.event("external_storage_reselected", ["newID": replacement])
                    }
                    let connected = available.contains { $0.uuid?.uuidString == selectedID }
                    self.logger.event("external_storage_state", ["connected": connected,
                        "selectedID": selectedID ?? "none",
                        "detected": available.map { $0.displayName ?? "SSD" }])
                    self.publish { self.externalStorageConnected = connected }
                    if !connected, self.activeExternalMovieURL != nil, let writer = self.realtimeLUTWriter {
                        writer.abort("外部 SSD 已断开连接")
                    }
                    if !connected, self.activeExternalMovieURL != nil,
                       #available(iOS 27.0, *), let writer = self.rawWriterExperiment as? RAWInternalWriterExperiment {
                        self.logger.event("raw_writer_ssd_disconnected")
                        writer.abort("外部 SSD 已断开连接")
                    }
                    if connected && self.clearStorageErrorOnReconnect {
                        self.clearStorageErrorOnReconnect = false
                        self.publish {
                            if self.storageSetupRequired {
                                self.errorText = nil
                                self.storageSetupRequired = false
                                if !self.recording && !self.finalizing { self.status = "Camera ready" }
                            }
                        }
                    }
                    self.attemptedPendingJobs.removeAll()
                    self.resumePendingIMU()
                }
            }
        }
    }

    /// Called after the main-thread preview layer has attached its session.
    func startCapture() {
        dispatchPrecondition(condition: .onQueue(.main))
        let allowed = UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
        queue.async {
            guard !self.startRequested else { return }
            self.startRequested = true
            self.finalizationAllowed = allowed
            self.logger.event("preview_attached_start", [:])
            #if DEBUG
            self.startResponsivenessProbe()
            #endif
            self.logger.whenReady { self.queue.async { self.requestCaptureAccess() } }
        }
    }
    private func requestCaptureAccess() {
        AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
            guard let self else { return }
            guard allowed else {
                self.queue.async { self.fail("Camera permission denied. Enable Camera in Settings.") }
                return
            }
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] audioAllowed in
                guard let self else { return }
                self.queue.async { self.configureSession(audioAllowed: audioAllowed) }
            }
        }
    }

    private func publish(_ update: @escaping () -> Void) { DispatchQueue.main.async(execute: update) }
    func previewGravity() -> RecordingGravity? { gravityMonitor.currentGravity() }
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { bytes in
            String(cString: bytes.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
    private func fail(_ message: String) {
        logger.event("error", ["message": message])
        publish { self.errorText = message; self.status = message }
    }
    private func failStorage(_ message: String, retryOnReconnect: Bool = false) {
        clearStorageErrorOnReconnect = retryOnReconnect
        logger.event("storage_error", ["message": message])
        publish { self.storageSetupRequired = true; self.errorText = message; self.status = message }
    }
    func refreshExternalStorage() {
        queue.async {
            let available = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
            var selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
            if !available.contains(where: { $0.uuid?.uuidString == selectedID }),
               available.count == 1, let replacement = available.first?.uuid?.uuidString {
                selectedID = replacement
                UserDefaults.standard.set(replacement, forKey: "externalDeviceID")
            }
            let connected = available.contains { $0.uuid?.uuidString == selectedID }
            self.publish { self.externalStorageConnected = connected }
        }
    }

    // Conservative estimate: RAW content/encoder bitrate varies; this is not a duration guarantee.
    private var conservativeBytesPerSecond: Double {
        let size = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let pixels = Double(size?.width ?? 3840) * Double(size?.height ?? 2160)
        if chosenEncoding == .hevc,
           let target = chosenHEVCBitratePreset.targetBitsPerSecond(
                width: size?.width ?? 3840, height: size?.height ?? 2160, fps: chosenFPS) {
            return Double(target) / 8 * 1.25 + 100_000
        }
        let bitsPerPixel = chosenEncoding.estimatedBitsPerPixelPerFrame
        return max(1_000_000, pixels * max(chosenFPS, 1) * bitsPerPixel / 8 + 100_000)
    }
    // Learned locally per hardware/lens/codec/format/rate, never from a single lab clip.
    private var bitrateProbeFile: URL?
    private var bitrateEstimator = RecordingRateEstimator()
    private var bitrateHistoryLastSaved: Double?
    private var capacityBitrateEstimator = RecordingRateEstimator()
    private var bitrateInitialCapacity: Int64?
    private var bitrateSampleBytes: Int64?
    private var liveBytesPerSecond: Double? { bitrateEstimator.bytesPerSecond ?? capacityBitrateEstimator.bytesPerSecond }
    private var bitrateStatisticsKey: String {
        let size = device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
        let base = "recordingBitrate.v1.\(Self.hardwareModel()).\(device?.uniqueID ?? "unknown").\(chosenEncoding.rawValue).\(size?.width ?? 0)x\(size?.height ?? 0).\(chosenFPS)"
        return chosenEncoding == .hevc ? base + ".\(chosenHEVCBitratePreset.rawValue)" : base
    }
    private var estimatedRecordingBytesPerSecond: Double {
        RecordingRateEstimator.displayRate(live: liveBytesPerSecond,
            learned: UserDefaults.standard.double(forKey: bitrateStatisticsKey),
            fallback: conservativeBytesPerSecond)
    }
    // SSD assessment keeps its existing headroom policy; the display uses actual
    // measured rates without imposing a theoretical codec-rate floor.
    private var estimatedBytesPerSecond: Double {
        max(estimatedRecordingBytesPerSecond, conservativeBytesPerSecond * 0.25)
    }
    private func updateRecordingBitrateEstimate(freeBytes: Int64?) {
        guard output.isRecording || rawWriterExperiment != nil || realtimeLUTWriter != nil, let file = currentFile else {
            bitrateProbeFile = nil; resetBitrateProbe()
            return
        }
        if bitrateProbeFile != file {
            bitrateProbeFile = file; resetBitrateProbe()
        }
        let now = ProcessInfo.processInfo.systemUptime
        // MovieFileOutput may stage the MOV elsewhere until stop. Its own byte
        // counter remains available while the destination URL does not yet exist.
        let bytes: Int64?
        if output.isRecording {
            bytes = output.recordedFileSize
        } else {
            bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value
        }
        bitrateSampleBytes = bytes
        if let bytes { bitrateEstimator.observe(bytes: bytes, at: now) }
        if ["专用视频存储", "外部 SSD"].contains(UserDefaults.standard.string(forKey: "storageLocation") ?? ""),
           let freeBytes {
            if bitrateInitialCapacity == nil { bitrateInitialCapacity = freeBytes }
            let consumed = max(0, (bitrateInitialCapacity ?? freeBytes) - freeBytes)
            capacityBitrateEstimator.observe(bytes: consumed, at: now)
        }
        guard let measured = liveBytesPerSecond,
              bitrateHistoryLastSaved.map({ now - $0 >= 10 }) ?? true else { return }
        // The rolling estimate is already smoothed. Do not blend an old
        // conservative estimate back in and keep the next launch biased short.
        UserDefaults.standard.set(measured, forKey: bitrateStatisticsKey)
        bitrateHistoryLastSaved = now
    }
    private func resetBitrateProbe() {
        bitrateEstimator = RecordingRateEstimator(); capacityBitrateEstimator = RecordingRateEstimator()
        bitrateHistoryLastSaved = nil; bitrateInitialCapacity = nil; bitrateSampleBytes = nil
    }
    private var storageReserveBytes: Int64 {
        // Leave enough headroom for queued writes, audio and metadata finalization.
        max(5_000_000_000, Int64(conservativeBytesPerSecond * 10))
    }
    private func freeRecordingBytes() -> Int64? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--storage-low-space-smoke") { return 100_000_000 }
        if args.contains("--storage-stop-smoke"), let start = movieFirstFrameHost,
           ProcessInfo.processInfo.systemUptime - start > 3 { return max(1, storageReserveBytes - 100_000_000) }
        #endif
        switch UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件" {
        case "专用视频存储":
            return ProVideoStorageBridge.isSupported() ? max(0, ProVideoStorageBridge.remainingCapacity()) : nil
        case "外部 SSD":
            let drives = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
            let id = UserDefaults.standard.string(forKey: "externalDeviceID")
            let drive = drives.first { $0.uuid?.uuidString == id } ?? (drives.count == 1 ? drives.first : nil)
            return drive.map { Int64(clamping: $0.freeSize) }
        default:
            return localFreeBytes()
        }
    }
    private func localFreeBytes() -> Int64? {
        (try? RecordingStoragePaths.movieDirectory.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?
            .volumeAvailableCapacity.map { Int64($0) }
    }
    func requestStorageReplenishment() {
        queue.async {
            self.storageReplenishPending = true
            self.storageReplenishFromDeletion = true
            self.storageReplenishRetries = 0
            self.storageReplenishNotBefore = 0
            self.replenishDeletedVideoStorageIfPossible()
        }
    }

    /// Reclaim on launch, foreground and deletion, including after reinstall or Files deletion.
    private func replenishDeletedVideoStorageIfPossible() {
        guard storageReplenishPending, ProcessInfo.processInfo.systemUptime >= storageReplenishNotBefore,
              !output.isRecording, !isRAWWriterActive,
              !recordingStarting, !captureFinishing else { return }
        guard #available(iOS 27.0, *), let storage = AVProVideoStorage.shared else {
            storageReplenishPending = false
            return
        }
        // The regular capacity refresh retries after system work has finished.
        guard storage.busyReasons.isEmpty else { return }
        // Internal H.265 deletions do not consume the reserved pool.
        guard storage.initialCapacity > 0, storage.remainingCapacity < storage.initialCapacity else {
            storageReplenishPending = false
            storageReplenishFromDeletion = false
            return
        }
        let before = storage.remainingCapacity
        let fromDeletion = storageReplenishFromDeletion
        storageReplenishPending = false
        storageReplenishFromDeletion = false
        logger.event("storage_replenish_begin", ["initialBytes": storage.initialCapacity,
            "remainingBytes": before, "localFreeBytes": localFreeBytes() ?? -1,
            "afterDeletion": fromDeletion])
        captureFinishing = true
        publish { self.finalizing = true; self.status = "正在回收专用存储空间…" }
        storage.replenishCapacity { capacity, error in
            self.queue.async {
                self.captureFinishing = false
                let nsError = error as NSError?
                self.logger.event("deleted_media_storage_replenished", ["remainingBytes": capacity,
                    "gainedBytes": capacity - before, "afterDeletion": fromDeletion,
                    "error": error?.localizedDescription ?? "", "errorDomain": nsError?.domain ?? "",
                    "errorCode": nsError?.code ?? 0, "localFreeBytes": self.localFreeBytes() ?? -1])
                // Existing recordings can keep capacity below the initial allocation.
                // Retry only a deletion that has not yet released blocks; a partial
                // successful reclaim must not keep the camera in Finalizing.
                if fromDeletion && error != nil && capacity <= before && self.storageReplenishRetries < 2 {
                    let delays = [2.0, 5.0]
                    self.storageReplenishNotBefore = ProcessInfo.processInfo.systemUptime + delays[self.storageReplenishRetries]
                    self.storageReplenishRetries += 1
                    self.storageReplenishPending = true
                    self.storageReplenishFromDeletion = true
                    self.logger.event("storage_replenish_retry_scheduled", ["attempt": self.storageReplenishRetries,
                        "remainingBytes": capacity, "initialBytes": storage.initialCapacity])
                }
                self.refreshStorageBudget()
                self.publish {
                    self.finalizing = false
                    self.status = error == nil || !fromDeletion ? "Camera ready" :
                        "专用存储空间回收未完成，请释放普通存储空间"
                }
                self.resumePendingIMU()
            }
        }
    }
    @discardableResult private func refreshStorageBudget() -> Int64? {
        let probeStart = ProcessInfo.processInfo.systemUptime
        defer {
            let elapsed = ProcessInfo.processInfo.systemUptime - probeStart
            if elapsed > 0.008 { logger.event("storage_probe_latency", ["seconds": elapsed]) }
        }
        let location = UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件"
        let free = freeRecordingBytes()
        updateRecordingBitrateEstimate(freeBytes: free)
        let remaining = free.map { max(0, Double($0 - storageReserveBytes) / estimatedRecordingBytesPerSecond) }
        publish {
            self.availableStorageBytes = free; self.estimatedRecordingSeconds = remaining
            self.checkedStorageLocation = location
        }
        var active = output.isRecording
        active = active || rawWriterExperiment != nil || realtimeLUTWriter != nil
        if active {
            logger.event("recording_storage_health", ["availableBytes": free ?? -1,
                "reserveBytes": storageReserveBytes, "localFreeBytes": localFreeBytes() ?? -1,
                "estimatedBytesPerSecond": estimatedRecordingBytesPerSecond,
                "liveBytesPerSecond": liveBytesPerSecond ?? -1,
                "rateWindowSeconds": bitrateEstimator.bytesPerSecond != nil
                    ? bitrateEstimator.measuredSeconds : capacityBitrateEstimator.measuredSeconds,
                "rateSampleBytes": bitrateSampleBytes ?? -1,
                "rateSource": bitrateEstimator.bytesPerSecond != nil
                    ? (output.isRecording ? "MovieFileOutput.recordedFileSize" : "MOV file length")
                    : (capacityBitrateEstimator.bytesPerSecond != nil ? "selected storage capacity consumption" : "history or codec estimate"),
                "remainingSeconds": remaining ?? -1])
        }
        if active && !storageStopRequested &&
            (free.map { $0 <= storageReserveBytes } == true || localFreeBytes().map { $0 < 500_000_000 } == true) {
            storageStopRequested = true
            logger.event("storage_safety_stop", ["availableBytes": free ?? -1, "reserveBytes": storageReserveBytes])
            publish { self.errorText = "剩余空间不足，已停止录制并开始保存。" }
            toggleRecording()
        }
        return free
    }
    private func storagePreflight() -> Bool {
        guard let free = refreshStorageBudget(), let local = localFreeBytes() else {
            if UserDefaults.standard.string(forKey: "storageLocation") == "外部 SSD" {
                failStorage("未检测到可用 SSD，请连接并在设置中选择目标 SSD。")
            } else {
                failStorage("无法读取剩余空间，请检查所选存储设备。")
            }
            return false
        }
        guard free > storageReserveBytes + Int64(conservativeBytesPerSecond * 10), local > 750_000_000 else {
            failStorage("剩余空间不足：需要保留封装空间及至少约 10 秒的录制容量。"); return false
        }
        storageStopRequested = false
        recordingCadenceWarning = nil
        output.minFreeDiskSpaceLimit = storageReserveBytes
        return true
    }

    private var recordingSlate = RecordingSlate()

    private func movieDestination(localDirectory: URL, baseName: String) throws -> (URL, Bool) {
        recordingSlate = RecordingSlate.load()
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--slate-smoke") {
            recordingSlate.production = "UITEST Slate QA"
            recordingSlate.director = "GyroCine Director"
            recordingSlate.cinematographer = "GyroCine Camera Operator"
            recordingSlate.scene = 12; recordingSlate.take = 3
        }
        #endif
        guard UserDefaults.standard.string(forKey: "storageLocation") == "外部 SSD" else {
            if baseName.hasPrefix("UITEST_") {
                var url = localDirectory.appendingPathComponent("\(baseName).mov")
                var suffix = 2
                while FileManager.default.fileExists(atPath: url.path) {
                    url = localDirectory.appendingPathComponent("\(baseName)-\(suffix).mov")
                    suffix += 1
                }
                return (url, false)
            }
            if UserDefaults.standard.string(forKey: "filenameType") != "simple" {
                return (recordingSlate.reserveURL(in: localDirectory), false)
            }
            let names = try FileManager.default.contentsOfDirectory(at: localDirectory,
                includingPropertiesForKeys: nil).compactMap { file -> Int? in
                guard file.pathExtension.lowercased() == "mov" else { return nil }
                let stem = file.deletingPathExtension().lastPathComponent
                guard stem.hasPrefix("IMG_") else { return nil }
                return Int(stem.dropFirst(4))
            }
            var index = max(UserDefaults.standard.integer(forKey: "nextInternalIMGIndex"),
                            (names.max() ?? 0) + 1, 1)
            var url = localDirectory.appendingPathComponent(String(format: "IMG_%04d.mov", index))
            while FileManager.default.fileExists(atPath: url.path) {
                index += 1
                url = localDirectory.appendingPathComponent(String(format: "IMG_%04d.mov", index))
            }
            UserDefaults.standard.set(index + 1, forKey: "nextInternalIMGIndex")
            return (url, false)
        }
        guard AVExternalStorageDevice.authorizationStatus == .authorized else {
            throw RecorderError.unavailable("外部 SSD 未授权，请在设置中选择 SSD 并允许访问")
        }
        let selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
        let connected = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter(\.isConnected) ?? []
        logger.event("external_storage_discovery", ["selectedID": selectedID ?? "none",
            "devices": connected.map { ["name": $0.displayName ?? "unknown", "id": $0.uuid?.uuidString ?? "none",
                                      "freeBytes": String($0.freeSize)] }])
        let exact = connected.first { $0.uuid?.uuidString == selectedID }
        guard let drive = exact ?? (connected.count == 1 ? connected.first : nil) else {
            throw RecorderError.unavailable("未检测到已选择的外部 SSD，请在设置中选择 SSD")
        }
        if exact == nil, let id = drive.uuid?.uuidString {
            UserDefaults.standard.set(id, forKey: "externalDeviceID")
            logger.event("external_storage_reselected", ["newID": id])
            publish { self.externalStorageConnected = true }
        }
        guard drive.freeSize < 0 || drive.freeSize >= 1_000_000_000 else {
            throw RecorderError.unavailable("SSD 剩余空间不足 1 GB，请更换 SSD")
        }
        guard let url = try drive.nextAvailableURLs(withPathExtensions: ["mov"]).first,
              url.startAccessingSecurityScopedResource() else {
            throw RecorderError.unavailable("无法获取 SSD 录制位置，请在设置中重新选择 SSD")
        }
        logger.event("external_movie_destination", ["drive": drive.displayName ?? "SSD", "path": url.path,
                                                     "freeBytes": drive.freeSize])
        return (url, true)
    }


    private func releaseExternalMovieAccess() {
        activeExternalMovieURL?.stopAccessingSecurityScopedResource()
        activeExternalMovieURL = nil
        activeExternalMovieBookmark = nil
    }
    private func prepareRAWWhiteBalance() throws {
        if chosenCodec?.rawValue != "aprn" && chosenCodec?.rawValue != "aprh" {
            if chosenWhiteBalance == .autoLock, !autoLockWhiteBalanceActive, let camera = device,
               camera.isWhiteBalanceModeSupported(.locked) {
                try camera.lockForConfiguration()
                camera.whiteBalanceMode = .locked
                camera.unlockForConfiguration()
                autoLockWhiteBalanceActive = true
                logger.event("white_balance_autol_locked", ["state": configurationSnapshot()])
                publish { self.whiteBalanceAuto = false }
            }
            return
        }
        guard chosenCodec?.rawValue == "aprn" || chosenCodec?.rawValue == "aprh",
              let camera = device else { return }
        try camera.lockForConfiguration()
        defer { camera.unlockForConfiguration() }
        restoreAutoWhiteBalanceAfterRecording = restoreAutoWhiteBalanceAfterRecording ||
            camera.whiteBalanceMode == .continuousAutoWhiteBalance
        if restoreAutoWhiteBalanceAfterRecording {
            guard camera.isWhiteBalanceModeSupported(.locked) else {
                throw RecorderError.unavailable("RAW 录制需要锁定白平衡，当前镜头不支持")
            }
            camera.whiteBalanceMode = .locked
        }
        logger.event("raw_white_balance_locked", ["mode": camera.whiteBalanceMode.rawValue,
                                                   "restoreAuto": restoreAutoWhiteBalanceAfterRecording])
        publish { self.whiteBalanceAuto = false }
    }
    private func logProVideoStorage(_ stage: String) {
        guard UserDefaults.standard.string(forKey: "storageLocation") == "专用视频存储" else { return }
        logger.event("pro_video_storage_diagnostic", ["stage": stage,
            "storage": ProVideoStorageBridge.diagnostics(for: output),
            "sessionRunning": session.isRunning, "recording": output.isRecording,
            "movieRotation": output.connection(with: .video)?.videoRotationAngle ?? -1,
            "state": configurationSnapshot(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "buildSDK": Bundle.main.object(forInfoDictionaryKey: "DTSDKName") ?? "unknown"])
    }

    private func prepareRAWRecordingPipeline() throws {
        guard chosenCodec?.rawValue == "aprn" || chosenCodec?.rawValue == "aprh",
              let camera = device else { return }
        try camera.lockForConfiguration()
        restoreAutoWhiteBalanceAfterRecording = camera.whiteBalanceMode == .continuousAutoWhiteBalance
        if camera.whiteBalanceMode != .locked {
            guard camera.isWhiteBalanceModeSupported(.locked) else {
                camera.unlockForConfiguration()
                throw RecorderError.unavailable("RAW 录制需要锁定白平衡，当前镜头不支持")
            }
            camera.whiteBalanceMode = .locked
        }
        camera.unlockForConfiguration()
        publish { self.whiteBalanceAuto = false }
        logger.event("raw_pipeline_prepare_begin", ["format": chosenIndex ?? -1, "fps": chosenFPS])
        logProVideoStorage("raw_before_stop")
        session.stopRunning()
        logProVideoStorage("raw_stopped")
        session.startRunning()
        logProVideoStorage("raw_started")
        guard session.isRunning else { throw RecorderError.unavailable("RAW 相机会话重启失败") }
        enableIntrinsicDelivery()
        rawPreparedSignature = currentRAWSignature
        rawPipelineReadyAt = ProcessInfo.processInfo.systemUptime + 0.5
        logger.event("raw_pipeline_prepare_complete", ["format": chosenIndex ?? -1, "fps": chosenFPS])
    }
    private var currentRAWSignature: String? {
        guard let codec = chosenCodec, ["aprn", "aprh"].contains(codec.rawValue),
              let camera = device, let index = chosenIndex else { return nil }
        return "\(camera.uniqueID)|\(codec.rawValue)|\(index)|\(chosenFPS)"
    }
    private func scheduleRAWPipelinePreparation() {
        guard !usesRAWWriterExperiment else {
            rawPreparedSignature = nil
            if #available(iOS 27.0, *) { queue.async { self.prepareRAWWriterPreview() } }
            return
        }
        guard currentRAWSignature != nil else { rawPreparedSignature = nil; return }
        rawPreparedSignature = nil
        queue.async {
            guard !self.usesRAWWriterExperiment, self.session.isRunning, !self.output.isRecording,
                  let signature = self.currentRAWSignature,
                  self.rawPreparedSignature != signature else { return }
            do {
                try self.prepareRAWRecordingPipeline()
                self.session.beginConfiguration()
                self.configureLUTPreview()
                self.session.commitConfiguration()
            }
            catch { self.restoreRAWWhiteBalance(); self.fail(error.localizedDescription) }
        }
    }
    private func restoreRAWWhiteBalance() {
        if chosenCodec?.rawValue == "aprn" || chosenCodec?.rawValue == "aprh" {
            restoreAutoWhiteBalanceAfterRecording = false
            autoLockWhiteBalanceActive = false
            if let camera = device {
                do {
                    try camera.lockForConfiguration()
                    applyWhiteBalancePreferenceLocked(camera)
                    camera.unlockForConfiguration()
                } catch { logger.event("white_balance_restore_failed", ["error": error.localizedDescription]) }
            }
            return
        }
        if autoLockWhiteBalanceActive, let camera = device {
            autoLockWhiteBalanceActive = false
            do {
                try camera.lockForConfiguration()
                applyWhiteBalancePreferenceLocked(camera)
                camera.unlockForConfiguration()
                logger.event("white_balance_autol_restored", ["state": configurationSnapshot()])
            } catch { logger.event("white_balance_restore_failed", ["error": String(describing: error)]) }
        }
        guard restoreAutoWhiteBalanceAfterRecording, let camera = device else { return }
        restoreAutoWhiteBalanceAfterRecording = false
        do {
            try camera.lockForConfiguration()
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            camera.unlockForConfiguration()
            publish { self.whiteBalanceAuto = true }
            logger.event("raw_white_balance_restored")
            rawPreparedSignature = nil
        } catch { logger.event("raw_white_balance_restore_failed", ["error": error.localizedDescription]) }
    }

    #if DEBUG
    private func restorePretestConfiguration() {
        guard let wide = lensDevices.values.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return }
        if device?.uniqueID != wide.uniqueID {
            chooseLens(wide.uniqueID)
            queue.asyncAfter(deadline: .now() + 2) { self.restorePretestConfiguration() }
            return
        }
        // The UI regression changed shutter, ISO and WB. The pretest screen
        // showed A-Max, auto ISO, zero EV and continuous AF.
        savedControls = SavedCameraControls()
        savedControls.save()
        UserDefaults.standard.set("angle", forKey: "exposureType")
        manualExposureIntent = nil
        chosenWhiteBalance = .auto
        manualWhiteBalanceKelvin = nil
        exposureBiasIntent = 0
        shutterMaxCustomized = false
        do { try resetCameraControls(wide, fps: chosenFPS, manualExposure: nil) }
        catch { logger.event("pretest_restore_controls_failed", ["error": String(describing: error)]) }
        guard let target = formatObjects.first(where: {
            $0.width == 4224 && $0.height == 2240 && $0.supports(60) &&
            $0.compatibleCodecs.contains(VideoEncoding.proResRAWHQ.codec.rawValue)
        }) else { logger.event("pretest_restore_unavailable"); return }
        chosenEncoding = .proResRAWHQ
        chosenCodec = chosenEncoding.codec
        chosenFPS = 60
        UserDefaults.standard.set("外部 SSD", forKey: "storageLocation")
        let restored = applyFormat(target.index, reason: "pretest_restore")
        refreshStorageBudget()
        logger.event("pretest_restore_result", ["success": restored, "state": configurationSnapshot()])
    }

    private func runRAWSSDSmoke() {
        if let lensType: AVCaptureDevice.DeviceType =
            ProcessInfo.processInfo.arguments.contains("--ssd-lens=0.5") ? .builtInUltraWideCamera :
            (ProcessInfo.processInfo.arguments.contains("--ssd-lens=4") ? .builtInTelephotoCamera : nil),
           let targetLens = lensDevices.values.first(where: { $0.deviceType == lensType }) {
            if device?.uniqueID != targetLens.uniqueID {
                chooseLens(targetLens.uniqueID)
                queue.asyncAfter(deadline: .now() + 2) { self.runRAWSSDSmoke() }
                return
            }
        }
        let longHQ = ProcessInfo.processInfo.arguments.contains("--raw-long-hq-ssd-smoke")
        guard UserDefaults.standard.string(forKey: "storageLocation") == "外部 SSD" else {
            logger.event("raw_smoke_failed", ["reason": "SSD is not selected"])
            return
        }
        let raw: VideoEncoding = longHQ || ProcessInfo.processInfo.arguments.contains("--raw-hq-ssd-smoke")
            ? .proResRAWHQ : .proResRAW
        let matrix = ProcessInfo.processInfo.arguments.contains("--ssd-matrix")
        let requestedFPS = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ssd-fps=") }
            .flatMap { Double($0.dropFirst("--ssd-fps=".count)) }
        let targetFPS = matrix ? (requestedFPS ?? 30) : (longHQ ? 24.0 : 30.0)
        let openGate = longHQ || ProcessInfo.processInfo.arguments.contains("--ssd-opengate")
        let candidates = formatObjects.filter {
            $0.compatibleCodecs.contains(raw.codec.rawValue) && $0.supports(targetFPS) &&
            $0.width >= 3840 && (openGate ? Double($0.width) / Double($0.height) < 1.65 :
                Double($0.width) / Double($0.height) >= 1.65)
        }
        guard let target = candidates.max(by: {
            ($0.format.autoFocusSystem == .none ? 0 : 1, Int64($0.width) * Int64($0.height)) <
            ($1.format.autoFocusSystem == .none ? 0 : 1, Int64($1.width) * Int64($1.height))
        }) else {
            logger.event("raw_smoke_unsupported", ["codec": raw.codec.rawValue, "fps": targetFPS, "openGate": openGate])
            return
        }
        chosenEncoding = raw; chosenCodec = raw.codec; chosenFPS = targetFPS
        guard applyFormat(target.index, reason: "raw_ssd_smoke") else {
            logger.event("raw_smoke_failed", ["reason": "RAW format selection failed"])
            return
        }
        logger.event("raw_smoke_configuration", ["format": target.index, "width": target.width,
                                                   "height": target.height, "fps": chosenFPS,
                                                   "codec": chosenCodec?.rawValue ?? "none"])
        queue.asyncAfter(deadline: .now() + 4) { self.toggleRecording() }
        if matrix { return } // Stop relative to didStart, not the configuration request.
        let stopDelay: Double = longHQ ? 244 :
            (ProcessInfo.processInfo.arguments.contains("--raw-hotplug-smoke") ? 45 : 11)
        queue.asyncAfter(deadline: .now() + stopDelay) {
            if self.output.isRecording || self.realtimeLUTWriter != nil { self.toggleRecording() }
            else { self.logger.event("raw_smoke_failed", ["reason": "MovieFileOutput never entered recording state"]) }
        }
    }

    // Debug-only support probe. Relaunch normally to restore the production session.
    private func runProStorageSupportProbe() {
        guard !output.isRecording else { return }
        logProVideoStorage("probe_full_session")
        session.stopRunning()
        session.beginConfiguration()
        session.removeOutput(intrinsicOutput)
        session.commitConfiguration()
        logProVideoStorage("probe_without_intrinsics_stopped")
        session.startRunning()
        logProVideoStorage("probe_without_intrinsics_running")
        session.stopRunning()
        session.beginConfiguration()
        for input in session.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput,
               deviceInput.device.hasMediaType(.audio) { session.removeInput(input) }
        }
        session.commitConfiguration()
        session.startRunning()
        logProVideoStorage("probe_movie_only_running")
        if let connection = output.connection(with: .video) {
            output.setOutputSettings([AVVideoCodecKey: "aprn"], for: connection)
            logProVideoStorage("probe_raw_codec_only_settings")
        }
        publish { self.cameraReady = false; self.status = "Storage probe complete; relaunch app" }
    }

    private func runProRes422Smoke() {
        prepareImportedLUTSmoke()
        guard let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--prores422-smoke=") }),
              let encoding = VideoEncoding(rawValue: String(argument.dropFirst("--prores422-smoke=".count))),
              encoding.isProRes422 else { return }
        let requestedColor = ProcessInfo.processInfo.arguments.first(where: {
            $0.hasPrefix("--prores422-color=")
        }).flatMap { RecordingColorSpace(rawValue: String($0.dropFirst("--prores422-color=".count))) }
            ?? (ProcessInfo.processInfo.arguments.contains("--prores422-log-smoke") ? .appleLog : .systemDefault)
        chosenEncoding = encoding
        chosenCodec = encoding.codec
        chosenFPS = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--prores422-fps=") }
            .flatMap { Double($0.dropFirst("--prores422-fps=".count)) } ?? 30
        chosenRecordingColorSpace = .systemDefault
        guard let target = closestFormatIndex(in: formatObjects, codec: encoding.codec,
            preference: CapturePreference(encoding: encoding, width: 3840, height: 2160, fps: chosenFPS)),
            applyFormat(target, reason: requestedColor == .systemDefault ? "color_space_change" : "prores422_smoke") else {
            logger.event("prores422_smoke_failed", ["codec": encoding.title, "reason": "configuration"])
            return
        }
        if requestedColor != .systemDefault {
            guard colorFormatIndex(near: target, color: requestedColor) != nil else {
                logger.event("prores422_smoke_failed", ["codec": encoding.title,
                    "reason": "Color space unavailable", "color": requestedColor.rawValue])
                return
            }
            session.stopRunning()
            chosenRecordingColorSpace = requestedColor
            guard applyFormat(target, reason: "prores422_color_smoke") else {
                session.startRunning()
                return
            }
            session.startRunning()
            publish { self.setLUTEnabled(true) }
        }
        logger.event("prores422_smoke_ready", ["codec": encoding.title, "color": chosenRecordingColorSpace.rawValue,
                                                 "state": configurationSnapshot()])
        startSmokeRecordingWhenReady(deadline: ProcessInfo.processInfo.systemUptime + 30)
    }

    private func runPointFocusSmoke(attempt: Int = 0) {
        guard let wide = lensDevices.values.first(where: { $0.deviceType == .builtInWideAngleCamera }) else { return }
        if device !== wide {
            guard attempt == 0 else { logger.event("point_focus_smoke_failed", ["reason": "wide lens unavailable"]); return }
            chooseLens(wide.uniqueID)
            queue.async { self.runPointFocusSmoke(attempt: attempt + 1) }
            return
        }
        let tap = CGPoint(x: 0.23, y: 0.37), hold = CGPoint(x: 0.71, y: 0.62)
        tapFocus(tap)
        queue.async {
            let tapOK = wide.focusMode == .continuousAutoFocus && wide.focusPointOfInterest == tap
            self.lockFocus(at: hold)
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.verifyPointFocusSmoke(tapOK: tapOK, point: hold,
                    deadline: ProcessInfo.processInfo.systemUptime + 8)
            }
        }
    }

    private func verifyPointFocusSmoke(tapOK: Bool, point: CGPoint, deadline: Double) {
        guard let camera = device else { return }
        if camera.isAdjustingFocus && ProcessInfo.processInfo.systemUptime < deadline {
            queue.asyncAfter(deadline: .now() + 0.1) {
                self.verifyPointFocusSmoke(tapOK: tapOK, point: point, deadline: deadline)
            }
            return
        }
        let snapshot = configurationSnapshot()
        let holdOK = chosenFocus == .locked && camera.focusPointOfInterest == point &&
            (camera.focusMode == .autoFocus || camera.focusMode == .locked) && !camera.isAdjustingFocus
        let position = camera.lensPosition
        queue.asyncAfter(deadline: .now() + 0.7) {
            let stable = abs(camera.lensPosition - position) < 0.005 && !camera.isAdjustingFocus
            self.tapFocus(CGPoint(x: 0.5, y: 0.5))
            self.queue.async {
                let released = self.chosenFocus == .continuous && camera.focusMode == .continuousAutoFocus
                let report: [String: Any] = ["pass": tapOK && holdOK && stable && released,
                    "tapPointApplied": tapOK, "heldPointApplied": holdOK,
                    "heldPositionStable": stable, "tapReleasesLock": released, "heldState": snapshot]
                self.logger.event("point_focus_smoke_result", report)
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                    try? data.write(to: RecordingStoragePaths.diagnosticDirectory.appendingPathComponent("focus-point-smoke-result.json"), options: .atomic)
                }
            }
        }
    }

    private func prepareImportedLUTSmoke() {
        if ProcessInfo.processInfo.arguments.contains("--lut-import-smoke") {
            do {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("UITEST_PreviewRed.cube")
                try ("LUT_3D_SIZE 2\n" + Array(repeating: "1 0 0", count: 8).joined(separator: "\n"))
                    .write(to: url, atomically: true, encoding: .utf8)
                let item = try PreviewLUTLibrary.importFile(url)
                try? FileManager.default.removeItem(at: url)
                UserDefaults.standard.set(item.selectionID, forKey: "previewImportedLUTID")
                UserDefaults.standard.set(true, forKey: "previewLUTEnabled")
                let items = PreviewLUTLibrary.load()
                publish { self.importedLUTs = items; self.selectImportedLUT(item); self.lutEnabled = true }
                logger.event("lut_import_smoke", ["id": item.selectionID, "name": item.name])
            } catch { logger.event("lut_import_smoke_failed", ["error": error.localizedDescription]); return }
        }
    }

    private func runHEVCCadenceSmoke() {
        if ProcessInfo.processInfo.arguments.contains("--lut-realtime-smoke") {
            UserDefaults.standard.removeObject(forKey: "previewImportedLUTID")
            UserDefaults.standard.set(true, forKey: "previewLUTEnabled")
            publish { self.setLUTLook(.rec709); self.setLUTBurnEnabled(true) }
        }
        prepareImportedLUTSmoke()
        if ProcessInfo.processInfo.arguments.contains("--whitebalance-autol-smoke") {
            chosenWhiteBalance = .autoLock
            savedControls.whiteBalance = WhiteBalanceChoice.autoLock.rawValue
            savedControls.save()
        }
        let at120 = ProcessInfo.processInfo.arguments.contains("--hevc-1080p120-smoke")
        let width: Int32 = at120 ? 1920 : 3840
        let height: Int32 = at120 ? 1080 : 2160
        let rate = at120 ? 120.0 : 60.0
        guard let target = formatObjects.filter({
            $0.width == width && $0.height == height && $0.supports(rate) &&
            $0.compatibleCodecs.contains(VideoEncoding.hevc.codec.rawValue)
        }).max(by: { ($0.format.autoFocusSystem == .none ? 0 : 1,
                     $0.supportsIntrinsics ? 1 : 0, -$0.index) <
                     ($1.format.autoFocusSystem == .none ? 0 : 1,
                     $1.supportsIntrinsics ? 1 : 0, -$1.index) }) else {
            logger.event("hevc_smoke_failed", ["reason": "No compatible HEVC format", "fps": rate])
            return
        }
        chosenEncoding = .hevc; chosenCodec = VideoEncoding.hevc.codec; chosenFPS = rate
        guard applyFormat(target.index, reason: "hevc_cadence_smoke") else { return }
        logger.event("hevc_smoke_configuration", ["format": target.index, "width": width,
                                                   "height": height, "fps": rate])
        startSmokeRecordingWhenReady(deadline: ProcessInfo.processInfo.systemUptime + 20)
    }

    /// Debug-only clock/exposure experiment. The completion timestamp marks
    /// the first camera buffer that used the requested exposure, in input-clock
    /// units. It must be converted before comparison with movie or IMU times.
    private func runIMUSyncExposureProbe(fileURL: URL) {
        let inputClock = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .first { $0.device.uniqueID == device?.uniqueID }?
            .ports.first { $0.mediaType == .video }?.clock
        let syncClock = session.synchronizationClock
        logger.event("imu_sync_probe_start", [
            "movie": fileURL.lastPathComponent,
            "firstVideoHostSeconds": movieFirstFrameHost ?? -1,
            "hostClockNowSeconds": CMClockGetTime(CMClockGetHostTimeClock()).seconds,
            "systemUptimeSeconds": ProcessInfo.processInfo.systemUptime,
            "firstGyroSeconds": imuRecorder?.firstGyroTime ?? -1,
            "inputClockAvailable": inputClock != nil,
            "syncClockAvailable": syncClock != nil
        ])
        for (delay, denominator) in [(1.5, 240.0), (5.5, 120.0), (9.5, 60.0)] {
            queue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.currentFile == fileURL, self.output.isRecording,
                      let camera = self.device else { return }
                let requested = 1.0 / denominator
                let minimum = camera.activeFormat.minExposureDuration.seconds
                let maximum = min(camera.activeFormat.maxExposureDuration.seconds,
                                  camera.activeVideoMaxFrameDuration.seconds)
                let seconds = max(minimum, min(requested, maximum))
                let iso = min(max(Float(400), camera.activeFormat.minISO), camera.activeFormat.maxISO)
                do {
                    try camera.lockForConfiguration()
                    camera.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                                 iso: iso) { [weak self] firstApplied in
                        guard let self else { return }
                        let sessionTime = inputClock.flatMap { source in
                            syncClock.map { CMSyncConvertTime(firstApplied, from: source, to: $0) }
                        }
                        let hostTime = inputClock.map {
                            CMSyncConvertTime(firstApplied, from: $0, to: CMClockGetHostTimeClock())
                        }
                        self.queue.async {
                            self.logger.event("imu_sync_exposure_applied", [
                                "requestedSeconds": requested,
                                "appliedSeconds": seconds,
                                "iso": iso,
                                "devicePTSSeconds": firstApplied.seconds,
                                "sessionPTSSeconds": sessionTime?.seconds ?? -1,
                                "hostPTSSeconds": hostTime?.seconds ?? -1,
                                "movieRelativeSeconds": (hostTime?.seconds ?? -1) -
                                    (self.movieFirstFrameHost ?? 0),
                                "callbackHostSeconds": CMClockGetTime(CMClockGetHostTimeClock()).seconds
                            ])
                        }
                    }
                    camera.unlockForConfiguration()
                    logger.event("imu_sync_exposure_requested", ["requestedSeconds": requested,
                        "appliedSeconds": seconds, "iso": iso])
                } catch {
                    logger.event("imu_sync_exposure_failed", ["message": error.localizedDescription])
                }
            }
        }
        queue.asyncAfter(deadline: .now() + 14.5) { [weak self] in
            guard let self, self.currentFile == fileURL, self.output.isRecording else { return }
            self.toggleRecording()
        }
    }

    private func startSmokeRecordingWhenReady(deadline: TimeInterval) {
        if session.isRunning && !captureFinishing && !recoveryInProgress && !recordingStarting {
            toggleRecording()
            // toggleRecording enqueues on the camera queue. Startup maintenance
            // can take the queue between this readiness check and that work.
            // Retry only if the queued attempt never entered recording.
            queue.asyncAfter(deadline: .now() + 0.6) {
                if !self.output.isRecording && !self.recordingStarting && self.currentFile == nil {
                    self.startSmokeRecordingWhenReady(deadline: deadline)
                }
            }
        } else if ProcessInfo.processInfo.systemUptime < deadline {
            queue.asyncAfter(deadline: .now() + 0.1) { self.startSmokeRecordingWhenReady(deadline: deadline) }
        } else {
            logger.event("error", ["message": "Test driver: camera/recovery not ready before deadline"])
        }
    }

    private func runKCapabilityProbe() {
        for info in formatObjects where info.width == 1920 && info.height == 1080 &&
            info.compatibleCodecs.contains(VideoEncoding.hevc.codec.rawValue) &&
            (info.supports(60) || info.supports(120)) {
            chosenEncoding = .hevc; chosenCodec = VideoEncoding.hevc.codec
            chosenFPS = info.supports(120) ? 120 : 60
            guard applyFormat(info.index, reason: "k_capability_probe") else { continue }
            let connection = intrinsicOutput.connection(with: .video)
            logger.event("k_capability_probe", ["format": info.index, "fps": chosenFPS,
                "pixelFormat": info.dictionary["pixelFormat"] ?? "unknown",
                "fovDegrees": info.format.videoFieldOfView,
                "intrinsicsSupported": connection?.isCameraIntrinsicMatrixDeliverySupported ?? false,
                "intrinsicsEnabled": connection?.isCameraIntrinsicMatrixDeliveryEnabled ?? false,
                "previewSized": intrinsicOutput.deliversPreviewSizedOutputBuffers])
        }
    }

    private func runExposureRetentionSmoke() {
        if ProcessInfo.processInfo.arguments.contains("--exposure-start-ultrawide"),
           let ultra = lensDevices.values.first(where: { $0.deviceType == .builtInUltraWideCamera }),
           device?.uniqueID != ultra.uniqueID {
            guard !exposureSmokeLensSwitchAttempted else {
                logger.event("exposure_smoke_failed", ["reason": "Could not select ultrawide lens"])
                return
            }
            exposureSmokeLensSwitchAttempted = true
            chooseLens(ultra.uniqueID)
            queue.asyncAfter(deadline: .now() + 2) { self.runExposureRetentionSmoke() }
            return
        }
        guard let camera = device,
              let wide = lensDevices.values.first(where: { $0.deviceType == .builtInWideAngleCamera }),
              let target = formatObjects.first(where: {
                  $0.width == 1920 && $0.height == 1080 && $0.supports(30) &&
                  $0.compatibleCodecs.contains(VideoEncoding.hevc.codec.rawValue)
              }) else { logger.event("exposure_smoke_failed", ["reason": "Missing camera or HEVC format"]); return }
        chosenEncoding = .hevc; chosenCodec = VideoEncoding.hevc.codec; chosenFPS = 30
        guard applyFormat(target.index, reason: "exposure_smoke") else { return }
        setManualExposure(seconds: 1/50, iso: 400)
        if ProcessInfo.processInfo.arguments.contains("--exposure-angle-smoke") { setShutterAngle(180) }
        queue.async { self.logger.event("exposure_smoke_before", self.configurationSnapshot()) }
        chooseLens(wide.uniqueID)
        queue.async {
            self.queue.asyncAfter(deadline: .now() + 1) {
                self.logger.event("exposure_smoke_after_lens", self.configurationSnapshot())
                self.chooseFPS(120)
                self.queue.async {
                    self.logger.event("exposure_smoke_after_fps", self.configurationSnapshot())
                    self.queue.asyncAfter(deadline: .now() + 1) {
                        self.logger.event("exposure_smoke_settled", self.configurationSnapshot())
                        self.logger.event("exposure_smoke_complete", ["startingLens": camera.uniqueID,
                                                                      "endingLens": self.device?.uniqueID ?? "none"])
                    }
                }
            }
        }
    }

    private func cleanupTestMovieWhenIdle(_ name: String, deadline: Double) {
        guard !captureFinishing, !recordingStarting, !recoveryInProgress, !isRAWWriterActive, !output.isRecording else {
            if ProcessInfo.processInfo.systemUptime < deadline {
                queue.asyncAfter(deadline: .now() + 1) { self.cleanupTestMovieWhenIdle(name, deadline: deadline) }
            } else { logger.event("failed_test_cleanup", ["movie": name, "error": "App remained busy"]) }
            return
        }
        deleteMedia([RecordingStoragePaths.movieDirectory.appendingPathComponent(name)]) { error in
            self.queue.async {
                if error == "录制尚未结束", ProcessInfo.processInfo.systemUptime < deadline {
                    self.queue.asyncAfter(deadline: .now() + 1) { self.cleanupTestMovieWhenIdle(name, deadline: deadline) }
                } else { self.logger.event("failed_test_cleanup", ["movie": name, "error": error ?? ""]) }
            }
        }
    }

    private func writeRAWSSDSmokeResult(_ job: PendingIMUJob, directory: URL) {
        let internalTest = ProcessInfo.processInfo.arguments.contains("--verify-internal-movie") &&
            job.movieName == currentFile?.lastPathComponent
        let recoveredTest = ProcessInfo.processInfo.arguments.contains("--verify-recovered-test-movie") &&
            job.movieName.hasPrefix("UITEST_IMG_writer_")
        guard job.movieName == rawSmokeMovieName || internalTest || recoveredTest else { return }
        verificationQueue.async { self.inspectRAWSSDSmokeResult(job, directory: directory) }
    }

    private func inspectRAWSSDSmokeResult(_ job: PendingIMUJob, directory: URL) {
        inspectRAWMovie(movieName: job.movieName, externalMovieBookmark: job.externalMovieBookmark,
            expectedFPS: job.expectedFPS, directory: directory)
    }

    private func inspectRAWMovie(movieName: String, externalMovieBookmark: Data?, expectedFPS: Double?, directory: URL) {
        logger.event("raw_verification_begin", ["movie": movieName])
        let movie: URL
        var accessing = false
        if let bookmark = externalMovieBookmark {
            var stale = false
            guard let external = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                          bookmarkDataIsStale: &stale), !stale,
                  external.startAccessingSecurityScopedResource() else { return }
            movie = external; accessing = true
        } else {
            movie = RecordingStoragePaths.movieDirectory.appendingPathComponent(movieName)
        }
        defer { if accessing { movie.stopAccessingSecurityScopedResource() } }
        do {
            let info = try MovieIMUFinalizer.inspect(movie)
            let asset = AVURLAsset(url: movie)
            let cadence = VideoCadenceHealth(frames: info.frames, fps: expectedFPS ?? 30)
            var decodedFrames = 0
            var decodeStatus = "notRequested"
            var decodeError = ""
            if ProcessInfo.processInfo.arguments.contains("--ssd-verify-decode"),
               let track = asset.tracks(withMediaType: .video).first {
                do {
                    let reader = try AVAssetReader(asset: asset)
                    let decoded = AVAssetReaderTrackOutput(track: track,
                        outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
                    decoded.alwaysCopiesSampleData = false
                    reader.add(decoded)
                    if reader.startReading() {
                        while autoreleasepool(invoking: { () -> Bool in
                            guard decoded.copyNextSampleBuffer() != nil else { return false }
                            decodedFrames += 1
                            if decodedFrames % 600 == 0 {
                                logger.event("raw_verification_progress", ["decodedFrames": decodedFrames,
                                    "totalFrames": info.frames.count, "movie": movieName])
                            }
                            return true
                        }) {}
                    }
                    decodeStatus = reader.status == .completed ? "completed" : "failed"
                    decodeError = reader.error?.localizedDescription ?? ""
                } catch { decodeStatus = "failed"; decodeError = error.localizedDescription }
            }
            let result: [String: Any] = ["movie": movie.lastPathComponent,
                "path": movie.path, "expectedFPS": expectedFPS ?? 0,
                "decodedFrames": decodedFrames, "decodeStatus": decodeStatus, "decodeError": decodeError,
                "maximumFrameGapMS": cadence.maximumGap * 1000,
                "estimatedMissingFrames": cadence.missingFrames,
                "averageFPS": Double(info.frames.count) / max(info.duration, 0.001),
                "bytes": (try? movie.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1,
                "codec": info.codecFourCC, "width": info.width, "height": info.height,
                "duration": info.duration, "frames": info.frames.count,
                "audioTracks": asset.tracks(withMediaType: .audio).count,
                "hasTelemetry": MOVTelemetryMuxer.hasTelemetry(movie)]
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("raw-ssd-smoke-result.json"), options: .atomic)
            logger.event("raw_smoke_result", result)
            if ProcessInfo.processInfo.arguments.contains("--writer-cleanup-verified"),
               movie.lastPathComponent.hasPrefix("UITEST_IMG_writer_"), !accessing,
               decodeStatus == "completed", decodedFrames == info.frames.count,
               MOVTelemetryMuxer.hasTelemetry(movie) {
                deleteMedia([movie]) { error in
                    self.logger.event("long_test_cleanup", ["movie": movie.lastPathComponent, "error": error ?? ""])
                }
            }
        } catch { logger.event("raw_smoke_failed", ["reason": error.localizedDescription]) }
    }

    private func inspectHotplugMovie() {
        let bookmarks = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] ?? []
        for bookmark in bookmarks {
            var stale = false
            guard let movie = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                        bookmarkDataIsStale: &stale), !stale,
                  movie.lastPathComponent == "IMG_0017.mov",
                  movie.startAccessingSecurityScopedResource() else { continue }
            defer { movie.stopAccessingSecurityScopedResource() }
            do {
                let info = try MovieIMUFinalizer.inspect(movie)
                let asset = AVURLAsset(url: movie)
                let handle = try FileHandle(forReadingFrom: movie)
                defer { try? handle.close() }
                let length = try handle.seekToEnd()
                var offset: UInt64 = 0
                var atoms: [[String: Any]] = []
                while offset + 8 <= length {
                    try handle.seek(toOffset: offset)
                    guard let header = try handle.read(upToCount: 8), header.count == 8 else { break }
                    let declared = header.uint(0, 4)
                    let type = String(decoding: header[4..<8], as: UTF8.self)
                    var size = declared
                    if size == 1 {
                        guard let extended = try handle.read(upToCount: 8), extended.count == 8 else { break }
                        size = extended.uint(0, 8)
                    } else if size == 0 { size = length - offset }
                    guard size >= 8, size <= length - offset else { break }
                    atoms.append(["type": type, "offset": offset, "size": size, "unbounded": declared == 0])
                    offset += size
                }
                let result: [String: Any] = ["movie": movie.lastPathComponent, "bytes": length,
                    "codec": info.codecFourCC, "duration": info.duration, "frames": info.frames.count,
                    "audioTracks": asset.tracks(withMediaType: .audio).count,
                    "hasTelemetry": MOVTelemetryMuxer.hasTelemetry(movie), "atoms": atoms]
                let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: logger.sessionURL.deletingLastPathComponent()
                    .appendingPathComponent("hotplug-recovered-inspection.json"), options: .atomic)
                logger.event("hotplug_recovered_inspection", result)
            } catch { logger.event("hotplug_inspection_failed", ["error": error.localizedDescription]) }
            return
        }
        logger.event("hotplug_inspection_failed", ["error": "Movie bookmark unavailable"])
    }

    #endif

    private func persistCaptureConfiguration() {
        guard let camera = device, let index = chosenIndex, formatObjects.indices.contains(index) else { return }
        let info = formatObjects[index]
        SavedCaptureConfiguration(lensID: camera.uniqueID, encoding: chosenEncoding.rawValue,
            width: info.width, height: info.height, fps: chosenFPS).save()
        UserDefaults.standard.set(chosenRecordingColorSpace.rawValue,
                                  forKey: "capture.colorSpace.\(camera.uniqueID)")
    }

    private func configureSession(audioAllowed: Bool) {
        let physicalLenses: [(AVCaptureDevice.DeviceType, String)] = [
            (.builtInUltraWideCamera, "0.5×"), (.builtInWideAngleCamera, "1×"),
            (.builtInTelephotoCamera, "4×")
        ]
        let discovered = physicalLenses.compactMap { type, label -> (AVCaptureDevice, LensChoice)? in
            guard let device = AVCaptureDevice.default(type, for: .video, position: .back) else { return nil }
            return (device, LensChoice(id: device.uniqueID, label: label))
        }
        lensDevices = Dictionary(uniqueKeysWithValues: discovered.map { ($0.0.uniqueID, $0.0) })
        let longRAWTest = ProcessInfo.processInfo.arguments.contains("--raw-long-hq-ssd-smoke")
        let saved = SavedCaptureConfiguration.load()
        let restoredCamera = saved.flatMap { lensDevices[$0.lensID] }
        #if DEBUG
        let forceWideProbe = ProcessInfo.processInfo.arguments.contains("--first-buffer-probe-wide")
        #else
        let forceWideProbe = false
        #endif
        guard let camera = ((longRAWTest || forceWideProbe) ? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) : nil)
            ?? restoredCamera
            ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(.builtInUltraWideCamera, for: .video, position: .back) else {
            fail("Rear physical camera unavailable"); return
        }
        device = camera
        publish { self.lenses = discovered.map(\.1); self.selectedLensID = camera.uniqueID }
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            session.beginConfiguration()
            session.sessionPreset = .inputPriority
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration(); fail("Cannot add camera input or movie output"); return
            }
            session.addInput(input); session.addOutput(output)
            if #available(iOS 26.0, *), output.isDeferredStartSupported {
                output.isDeferredStartEnabled = false
                logger.event("movie_deferred_start_disabled")
            }
            intrinsicOutput.alwaysDiscardsLateVideoFrames = true
            intrinsicOutput.automaticallyConfiguresOutputBufferDimensions = false
            intrinsicOutput.deliversPreviewSizedOutputBuffers = false
            intrinsicOutput.setSampleBufferDelegate(previewFanout, queue: intrinsicRecorder.queue)
            guard session.canAddOutput(intrinsicOutput) else {
                session.commitConfiguration(); fail("Cannot add camera intrinsics output"); return
            }
            session.addOutput(intrinsicOutput)
            enableIntrinsicDelivery()
            if audioAllowed, let microphone = AVCaptureDevice.default(for: .audio) {
                let audioInput = try AVCaptureDeviceInput(device: microphone)
                guard session.canAddInput(audioInput) else {
                    session.commitConfiguration(); fail("Cannot add microphone input"); return
                }
                session.addInput(audioInput)
                let stereoSupported = audioInput.isMultichannelAudioModeSupported(.stereo)
                if stereoSupported { audioInput.multichannelAudioMode = .stereo }
                logger.event("audio_capture_mode", ["stereoSupported": stereoSupported,
                    "mode": audioInput.multichannelAudioMode.rawValue])
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") {
                intrinsicRecorder.timestampProbe = captureStartProbe
                if audioReady || audioAllowed {
                    if session.canAddOutput(captureStartProbe.audioOutput) {
                        session.addOutput(captureStartProbe.audioOutput)
                        logger.event("first_buffer_probe_audio_output", ["added": true])
                    } else {
                        logger.event("first_buffer_probe_audio_output", ["added": false])
                    }
                }
            }
            #endif
            session.commitConfiguration()
            audioReady = audioAllowed && session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.audio) == true }
            publish { self.audioAvailable = self.audioReady }
            publish { self.imuAvailable = IMURecorder().isAvailable }
            logger.event("camera_ready", ["deviceID": camera.uniqueID, "name": camera.localizedName,
                                          "audioAuthorized": audioAllowed,
                                          "supportsFocusPoint": camera.isFocusPointOfInterestSupported,
                                          "supportsSmoothAutoFocus": camera.isSmoothAutoFocusSupported,
                                          "formatCount": camera.formats.count])
            installFocusObservers(camera)
            publish {
                self.actualFocusMode = self.focusName(camera.focusMode)
                self.adjusting = camera.isAdjustingFocus
                self.lensPosition = camera.lensPosition
            }
            publish { self.isoRange = Double(camera.activeFormat.minISO)...Double(camera.activeFormat.maxISO) }
            let preference = saved.flatMap { value -> CapturePreference? in
                guard let encoding = VideoEncoding(rawValue: value.encoding) else { return nil }
                return CapturePreference(encoding: encoding, width: value.width, height: value.height, fps: value.fps)
            }
            self.chosenRecordingColorSpace = RecordingColorSpace.restored(
                UserDefaults.standard.string(forKey: "capture.colorSpace.\(camera.uniqueID)"))
            guard discoverCapabilities(camera, preference: longRAWTest ? nil : preference, manualExposure: manualExposureIntent) else { return }
            startSampling(camera)
            session.startRunning()
            applyRulerHaptics(UserDefaults.standard.bool(forKey: "rulerHaptics"))
            captureConfigured = true
            queue.async { self.resumePendingIMU() }
            let telemetryEmbeddable = currentTelemetrySupport
            let running = session.isRunning
            publish {
                self.status = "Camera ready"; self.cameraReady = running
                self.telemetryEmbeddable = telemetryEmbeddable
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ssd-speed-probe") {
                runSSDSpeedTestWhenIdle(deadline: ProcessInfo.processInfo.systemUptime + 90)
            }
            if ProcessInfo.processInfo.arguments.contains("--restore-pretest-configuration") {
                restorePretestConfiguration()
            }
            if let name = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--cleanup-test-file=") })?.dropFirst("--cleanup-test-file=".count),
               name.hasPrefix("UITEST_IMG_writer_"), !name.contains("/"), name.hasSuffix(".mov") {
                cleanupTestMovieWhenIdle(String(name), deadline: ProcessInfo.processInfo.systemUptime + 30)
            }
            if let name = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--verify-existing-test=") })?.dropFirst("--verify-existing-test=".count),
               name.hasPrefix("UITEST_IMG_writer_"), !name.contains("/"), name.hasSuffix(".mov") {
                let fps = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--verify-existing-fps=") }
                    .flatMap { Double($0.dropFirst("--verify-existing-fps=".count)) } ?? 30
                verificationQueue.async {
                    self.inspectRAWMovie(movieName: String(name), externalMovieBookmark: nil, expectedFPS: fps,
                        directory: self.logger.sessionURL.deletingLastPathComponent())
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--raw-writer-integrated-auto") { runRAWWriterIntegratedSmoke() }
            if ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--prores422-smoke=") }) {
                runProRes422Smoke()
            }
            if ProcessInfo.processInfo.arguments.contains("--lut-prores-file-smoke") {
                finalizationQueue.async {
                    let source = RecordingStoragePaths.movieDirectory.appendingPathComponent("UITEST_LUT_PRORES.mov")
                    for codec in ["apco", "apcs", "apcn", "apch"] {
                        let movie = RecordingStoragePaths.movieDirectory.appendingPathComponent("UITEST_LUT_PRORES_\(codec).mov")
                        do {
                            try? FileManager.default.removeItem(at: movie)
                            try FileManager.default.copyItem(at: source, to: movie)
                            let cube = try CubeLook(text: "LUT_3D_SIZE 2\n" + Array(repeating: "1 0 0", count: 8).joined(separator: "\n"))
                                .compose(technical: PreviewColorTransform.cube(.rec709))
                            let recipe = LUTBurnRecipe(id: "UITEST_PRORES_\(codec)", cube: cube, codec: codec, highBitDepth: true)
                            try LUTMovieBurner.apply(recipe, movie: movie, progress: nil)
                            // Repeating the durable job must preserve the completed file byte-for-byte.
                            let completed = try Data(contentsOf: movie)
                            try LUTMovieBurner.apply(recipe, movie: movie, progress: nil)
                            guard try Data(contentsOf: movie) == completed else { throw RecorderError.unavailable("LUT retry was not idempotent") }
                            self.logger.event("lut_prores_file_result", ["pass": true, "codec": codec])
                        } catch { self.logger.event("lut_prores_file_result", ["pass": false, "codec": codec, "error": String(describing: error)]) }
                    }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--cleanup-lut-smoke") {
                lutImportQueue.async {
                    do {
                        for item in PreviewLUTLibrary.load() where item.name == "UITEST_PreviewRed" {
                            try PreviewLUTLibrary.remove(item)
                        }
                        let items = PreviewLUTLibrary.load()
                        self.publish {
                            self.importedLUTs = items
                            if self.selectedImportedLUT == nil { self.setLUTLook(.rec709); self.setLUTEnabled(false) }
                        }
                    } catch { self.logger.event("lut_smoke_cleanup_failed", ["error": error.localizedDescription]) }
                }
            }
            if ProcessInfo.processInfo.arguments.contains("--focus-point-smoke") { runPointFocusSmoke() }
            if ProcessInfo.processInfo.arguments.contains("--pro-storage-support-probe") { runProStorageSupportProbe() }
            if ProcessInfo.processInfo.arguments.contains("--raw-ssd-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--raw-hq-ssd-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--raw-long-hq-ssd-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--raw-hotplug-smoke") { runRAWSSDSmoke() }
            if ProcessInfo.processInfo.arguments.contains("--hevc-4k60-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") ||
               ProcessInfo.processInfo.arguments.contains("--imu-sync-4k60-probe") ||
               ProcessInfo.processInfo.arguments.contains("--hevc-1080p120-smoke") { runHEVCCadenceSmoke() }
            if ProcessInfo.processInfo.arguments.contains("--k-capability-probe") { runKCapabilityProbe() }
            if ProcessInfo.processInfo.arguments.contains("--k-wide-lens-probe"),
               let wide = lensDevices.values.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
                chooseLens(wide.uniqueID)
            }
            if ProcessInfo.processInfo.arguments.contains("--exposure-retention-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--exposure-angle-smoke") { runExposureRetentionSmoke() }
            if ProcessInfo.processInfo.arguments.contains("--inspect-hotplug") { inspectHotplugMovie() }
            #endif
        } catch { fail("Camera setup: \(error)") }
    }

    private func enableIntrinsicDelivery() {
        guard let connection = intrinsicOutput.connection(with: .video) else { return }
        if connection.isCameraIntrinsicMatrixDeliverySupported && !connection.isCameraIntrinsicMatrixDeliveryEnabled {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }

    func chooseLens(_ id: String, completion: (() -> Void)? = nil) {
        queue.async {
            defer { if let completion { self.publish(completion) } }
            guard !self.output.isRecording, !self.recordingStarting, !self.captureFinishing else {
                self.fail("Lens cannot change during recording"); return
            }
            guard let current = self.device, current.uniqueID != id,
                  let next = self.lensDevices[id],
                  let oldInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                    .first(where: { $0.device.uniqueID == current.uniqueID && $0.device.hasMediaType(.video) }) else { return }
            self.publish { self.switchingLens = true }
            let currentFormat = self.chosenIndex.flatMap { self.formatObjects.indices.contains($0) ? self.formatObjects[$0] : nil }
            let preference = CapturePreference(encoding: self.chosenEncoding,
                width: currentFormat?.width ?? 3840, height: currentFormat?.height ?? 2160, fps: self.chosenFPS)
            let manualExposure = self.manualExposurePreference(current)
            let previousFormats = self.formatObjects
            let previousCodecs = self.supportedCodecs
            let previousIndex = self.chosenIndex
            self.logger.event("lens_switch_request", ["from": current.uniqueID, "to": id,
                "replacedInput": oldInput.device.localizedName,
                "sessionInputs": self.session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device.localizedName },
                "before": self.configurationSnapshot()])
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            defer { if wasRunning { self.session.startRunning() } }
            do {
                let newInput = try AVCaptureDeviceInput(device: next)
                self.session.beginConfiguration()
                self.restoreRAWPreviewForConfiguration()
                self.session.removeInput(oldInput)
                guard self.session.canAddInput(newInput) else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraError.unsupportedFocus("Camera input unavailable")
                }
                self.session.addInput(newInput)
                self.enableIntrinsicDelivery()
                self.session.commitConfiguration()
                self.observations.removeAll()
                self.sampleTimer?.cancel(); self.sampleTimer = nil
                self.device = next
                self.installFocusObservers(next)
                self.startSampling(next)
                guard self.discoverCapabilities(next, preference: preference, manualExposure: manualExposure) else {
                    throw CameraError.unsupportedFocus("No compatible configuration on selected lens")
                }
                self.logger.event("lens_switch_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish {
                    self.selectedLensID = id
                    self.actualFocusMode = self.focusName(next.focusMode)
                    self.lensPosition = next.lensPosition
                    self.isoRange = Double(next.activeFormat.minISO)...Double(next.activeFormat.maxISO)
                    self.switchingLens = false
                }
            } catch {
                if self.device?.uniqueID == next.uniqueID {
                    self.session.beginConfiguration()
                    if let inserted = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput })
                        .first(where: { $0.device.uniqueID == next.uniqueID }) {
                        self.session.removeInput(inserted)
                    }
                    let restored = self.session.canAddInput(oldInput)
                    if restored { self.session.addInput(oldInput); self.enableIntrinsicDelivery() }
                    self.session.commitConfiguration()
                    if restored {
                        self.observations.removeAll()
                        self.sampleTimer?.cancel(); self.sampleTimer = nil
                        self.device = current
                        self.formatObjects = previousFormats; self.supportedCodecs = previousCodecs
                        self.chosenEncoding = preference.encoding; self.chosenCodec = preference.encoding.codec
                        self.chosenIndex = previousIndex; self.chosenFPS = preference.fps
                        self.installFocusObservers(current); self.startSampling(current)
                        if let previousIndex { _ = self.applyFormat(previousIndex, reason: "lens_rollback", manualExposure: manualExposure) }
                        self.publish { self.formats = previousFormats; self.codecs = previousCodecs; self.selectedLensID = current.uniqueID }
                    }
                }
                self.logger.event("lens_switch_result", ["success": false, "error": String(describing: error)])
                self.publish { self.switchingLens = false }
                self.fail("Lens switch: \(error)")
            }
        }
    }

    @discardableResult private func discoverCapabilities(_ camera: AVCaptureDevice, preference: CapturePreference? = nil,
                                                         manualExposure: ManualExposurePreference? = nil) -> Bool {
        let oldFormat = camera.activeFormat
        let oldMin = camera.activeVideoMinFrameDuration
        let oldMax = camera.activeVideoMaxFrameDuration
        var found: [FormatInfo] = []
        var union: [AVVideoCodecType] = []
        var proResProbe: [String: Bool] = [:]
        session.beginConfiguration()
        func restoreProbe() {
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = oldFormat
                camera.activeVideoMinFrameDuration = oldMin
                camera.activeVideoMaxFrameDuration = oldMax
                camera.unlockForConfiguration()
            } catch { logger.event("probe_restore_error", ["error": String(describing: error)]) }
            session.commitConfiguration()
        }
        for (index, format) in camera.formats.enumerated() {
            var info = FormatInfo(index: index, format: format)
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = format
                camera.unlockForConfiguration()
                var available = output.availableVideoCodecTypes
                // Probe the actual encoder, once per codec/raster. Capture must also
                // expose a video-data connection; RAW formats are not candidates.
                if available.contains(.hevc), intrinsicOutput.connection(with: .video) != nil {
                    for encoding in VideoEncoding.allCases where encoding.isProRes422 && !available.contains(encoding.codec) {
                        let key = "\(encoding.codec.rawValue)-\(info.width)x\(info.height)"
                        if proResProbe[key] == nil {
                            var encoder: VTCompressionSession?
                            let code = encoding.codec.rawValue.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                            let status = VTCompressionSessionCreate(allocator: nil, width: info.width, height: info.height,
                                codecType: code, encoderSpecification: nil, imageBufferAttributes: nil,
                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &encoder)
                            proResProbe[key] = status == noErr && encoder != nil
                            if let encoder { VTCompressionSessionInvalidate(encoder) }
                        }
                        if proResProbe[key] == true { available.append(encoding.codec) }
                    }
                }
                info.compatibleCodecs = Set(available.map(\.rawValue))
                info.supportsIntrinsics = intrinsicOutput.connection(with: .video)?
                    .isCameraIntrinsicMatrixDeliverySupported ?? false
                for codec in available where !union.contains(codec) { union.append(codec) }
                logger.event("format_probe", ["index": index, "availableCodecs": available.map(\.rawValue)])
            } catch {
                logger.event("format_probe_error", ["index": index, "error": String(describing: error)])
            }
            found.append(info)
        }
        restoreProbe()
        formatObjects = found
        let preferredEncoding = preference?.encoding ?? .hevc
        let encodingOrder: [VideoEncoding] = switch preferredEncoding {
        case .hevc: [.hevc, .hevcHQ, .proResRAW, .proResRAWHQ]
        case .hevcHQ: [.hevcHQ, .hevc, .proResRAW, .proResRAWHQ]
        case .proResRAW: [.proResRAW, .proResRAWHQ, .hevcHQ, .hevc]
        case .proResRAWHQ: [.proResRAWHQ, .proResRAW, .hevcHQ, .hevc]
        case .proRes422HQ: [.proRes422HQ, .proRes422, .proRes422LT, .hevcHQ, .hevc]
        case .proRes422: [.proRes422, .proRes422HQ, .proRes422LT, .hevcHQ, .hevc]
        case .proRes422LT: [.proRes422LT, .proRes422, .proRes422Proxy, .hevcHQ, .hevc]
        case .proRes422Proxy: [.proRes422Proxy, .proRes422LT, .proRes422, .hevcHQ, .hevc]
        }
        guard let encoding = encodingOrder.first(where: { candidate in
            found.contains { $0.compatibleCodecs.contains(candidate.codec.rawValue) &&
                !availableFPS(for: $0).isEmpty }
        }) else {
            fail("No supported video encoding on selected lens"); return false
        }
        chosenEncoding = encoding
        chosenCodec = encoding.codec
        let originalIndex = found.firstIndex(where: { $0.format === oldFormat })
        if let preference {
            chosenFPS = CaptureFrameRatePolicy.normalized(preference.fps)
            chosenIndex = closestFormatIndex(in: found, codec: encoding.codec,
                preference: CapturePreference(encoding: encoding, width: preference.width,
                    height: preference.height, fps: chosenFPS))
        } else {
            chosenFPS = 60
            chosenIndex = closestFormatIndex(in: found, codec: encoding.codec,
                    preference: CapturePreference(encoding: encoding, width: 3840, height: 2160, fps: 60))
                ?? originalIndex.flatMap { found[$0].compatibleCodecs.contains(encoding.codec.rawValue) ? $0 : nil }
                ?? found.firstIndex(where: { $0.compatibleCodecs.contains(encoding.codec.rawValue) })
        }
        if let index = chosenIndex {
            chosenIndex = preferredIntrinsicFormatIndex(near: index, fps: chosenFPS,
                                                        codec: encoding.codec, in: found)
        }
        let report: [String: Any] = ["sessionID": logger.sessionID, "model": Self.hardwareModel(),
                                     "iOS": UIDevice.current.systemVersion, "cameraID": camera.uniqueID,
                                     "cameraName": camera.localizedName, "allCodecs": union.map(\.rawValue),
                                     "focusCapabilities": ["focusPoint": camera.isFocusPointOfInterestSupported,
                                                           "manualLensPosition": camera.isLockingFocusWithCustomLensPositionSupported,
                                                           "continuous": camera.isFocusModeSupported(.continuousAutoFocus),
                                                           "single": camera.isFocusModeSupported(.autoFocus),
                                                           "locked": camera.isFocusModeSupported(.locked)],
                                     "formats": found.map(\.dictionary)]
        logger.capabilityReport(report)
        supportedCodecs = union.filter { codec in
            found.contains { $0.compatibleCodecs.contains(codec.rawValue) && !availableFPS(for: $0).isEmpty }
        }
        logger.event("capability_summary", ["formatCount": found.count, "codecs": union.map(\.rawValue),
                                            "reportPath": logger.capabilityURL.path])
        publish {
            self.formats = found; self.codecs = union; self.selectedCodec = encoding.codec
            self.selectedEncoding = encoding
            if encoding.isRAW { self.setLUTBurnEnabled(false) }
            self.selectedFormatIndex = self.chosenIndex
        }
        guard let index = chosenIndex else { fail("No compatible format on selected lens"); return false }
        let applied = applyFormat(index, reason: preference == nil ? "initial_selection" : "lens_switch",
                                  manualExposure: manualExposure)
        if applied, let preference {
            logger.event("lens_configuration_fallback", ["requested": [preference.encoding.title, "\(preference.width)×\(preference.height)", preference.fps],
                                                       "chosen": configurationSnapshot()])
        }
        return applied
    }

    func chooseEncoding(_ encoding: VideoEncoding) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting, !self.captureFinishing else { self.fail("Codec cannot change during recording"); return }
            let codec = encoding.codec
            guard self.supportedCodecs.contains(codec) else { self.fail("Codec unavailable: \(codec.rawValue)"); return }
            let before = self.configurationSnapshot()
            let target = self.chosenIndex.flatMap { self.formatObjects[$0].compatibleCodecs.contains(codec.rawValue) ? $0 : nil }
                ?? self.chosenIndex.flatMap { index in
                    let current = self.formatObjects[index]
                    return self.closestFormatIndex(in: self.formatObjects, codec: codec,
                        preference: CapturePreference(encoding: encoding, width: current.width,
                                                       height: current.height, fps: self.chosenFPS))
                }
                ?? self.formatObjects.firstIndex(where: { $0.compatibleCodecs.contains(codec.rawValue) })
            self.logger.event("codec_request", ["requested": encoding.title, "before": before])
            guard let target else { self.fail("No compatible format for \(codec.rawValue)"); return }
            let previousCodec = self.chosenCodec
            let previousEncoding = self.chosenEncoding
            self.chosenCodec = codec
            self.chosenEncoding = encoding
            if !self.applyFormat(target, reason: "codec_change") {
                self.chosenCodec = previousCodec; self.chosenEncoding = previousEncoding
            }
        }
    }

    func chooseRecordingColorSpace(_ colorSpace: RecordingColorSpace) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting, !self.captureFinishing,
                  self.rawWriterExperiment == nil, let index = self.chosenIndex,
                  self.formatObjects.indices.contains(index) else {
                self.fail("Color space cannot change during recording"); return
            }
            guard self.colorFormatIndex(near: index, color: colorSpace) != nil else {
                self.fail("Color space unavailable for this format"); return
            }
            guard self.chosenRecordingColorSpace != colorSpace else { return }
            let previous = self.chosenRecordingColorSpace
            let wasRunning = self.session.isRunning
            if wasRunning { self.session.stopRunning() }
            self.chosenRecordingColorSpace = colorSpace
            if !self.applyFormat(index, reason: "color_space_change") {
                self.chosenRecordingColorSpace = previous
            }
            if wasRunning { self.session.startRunning() }
        }
    }

    func setHEVCBitratePreset(_ preset: HEVCBitratePreset) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting, !self.captureFinishing,
                  self.rawWriterExperiment == nil else {
                self.fail("Bitrate cannot change during recording"); return
            }
            guard self.chosenEncoding == .hevc, let index = self.chosenIndex,
                  self.formatObjects.indices.contains(index),
                  let connection = self.output.connection(with: .video) else {
                self.fail("H.265 bitrate is unavailable for this configuration"); return
            }
            let previous = self.chosenHEVCBitratePreset
            self.chosenHEVCBitratePreset = preset
            do {
                let settings = try self.encodingSettings(for: self.formatObjects[index],
                                                         fps: self.chosenFPS, connection: connection)
                if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                    self.output.setOutputSettings(settings, for: connection)
                }) { throw CameraError.unsupportedFocus("Bitrate settings: \(exception)") }
                UserDefaults.standard.set(preset.rawValue, forKey: "hevcBitratePreset")
                self.logger.event("hevc_bitrate_preset", ["preset": preset.rawValue,
                    "targetBitsPerSecond": preset.targetBitsPerSecond(
                        width: self.formatObjects[index].width,
                        height: self.formatObjects[index].height, fps: self.chosenFPS) as Any? ?? NSNull()])
                self.publish { self.hevcBitratePreset = preset; self.errorText = nil }
                self.resetBitrateProbe()
                self.refreshStorageBudget()
                self.refreshSSDSpeedAssessment()
            } catch {
                self.chosenHEVCBitratePreset = previous
                if let old = try? self.encodingSettings(for: self.formatObjects[index],
                                                        fps: self.chosenFPS, connection: connection) {
                    _ = RecordingExceptionCatcher.exceptionMessage(for: {
                        self.output.setOutputSettings(old, for: connection)
                    })
                }
                self.fail("H.265 bitrate: \(error)")
            }
        }
    }

    func chooseFormat(_ index: Int) {
        queue.async {
            guard let codec = self.chosenCodec else { return }
            guard self.formatObjects.indices.contains(index),
                  !self.availableFPS(for: self.formatObjects[index]).isEmpty else {
                self.fail("No supported frame rate at the selected resolution"); return
            }
            let selected = self.preferredIntrinsicFormatIndex(near: index, fps: self.chosenFPS,
                                                               codec: codec, in: self.formatObjects)
            self.applyFormat(selected, reason: "format_change")
        }
    }

    private func colorFormatIndex(near index: Int, color: RecordingColorSpace) -> Int? {
        guard formatObjects.indices.contains(index) else { return nil }
        let current = formatObjects[index]
        if color.isAvailable(for: current.format, encoding: chosenEncoding), current.supports(chosenFPS) { return index }
        return formatObjects.filter {
            $0.width == current.width && $0.height == current.height && $0.supports(chosenFPS) &&
            $0.compatibleCodecs.contains(chosenEncoding.codec.rawValue) &&
            color.isAvailable(for: $0.format, encoding: chosenEncoding)
        }.min {
            ($0.supportsIntrinsics ? 0 : 1, abs($0.index - index)) <
            ($1.supportsIntrinsics ? 0 : 1, abs($1.index - index))
        }?.index
    }

    @discardableResult private func applyFormat(_ requestedIndex: Int, reason: String,
                                                manualExposure: ManualExposurePreference? = nil) -> Bool {
        if !chosenEncoding.isRAW, chosenRecordingColorSpace == .systemDefault { chosenRecordingColorSpace = .rec709 }
        let index = colorFormatIndex(near: requestedIndex, color: chosenRecordingColorSpace) ?? requestedIndex
        guard !output.isRecording, !recordingStarting, !captureFinishing else { fail("Format cannot change during recording"); return false }
        guard let camera = device, let codec = chosenCodec, formatObjects.indices.contains(index) else { fail("Invalid format selection"); return false }
        let info = formatObjects[index]
        guard info.compatibleCodecs.contains(codec.rawValue) else { fail("Format [\(index)] does not support \(codec.rawValue)"); return false }
        guard !availableFPS(for: info).isEmpty else { fail("Format [\(index)] has no enabled frame rate"); return false }
        let before = configurationSnapshot()
        let previousFormat = camera.activeFormat
        let previousMin = camera.activeVideoMinFrameDuration
        let previousMax = camera.activeVideoMaxFrameDuration
        let previousColorSpace = camera.activeColorSpace
        let previousAutomaticWideColor = session.automaticallyConfiguresCaptureDeviceForWideColor
        let requestedColorSpace: RecordingColorSpace = chosenEncoding.isRAW ? .systemDefault :
            (chosenRecordingColorSpace.isAvailable(for: info.format, encoding: chosenEncoding) ? chosenRecordingColorSpace :
             RecordingColorSpace.selectableCases.first { $0.isAvailable(for: info.format, encoding: chosenEncoding) } ?? .rec709)
        let exposureToRestore = manualExposure ?? (reason != "initial_selection" ? manualExposurePreference(camera) : nil)
        logger.event("configuration_request", ["kind": reason, "requestedCodec": codec.rawValue, "requestedFormat": index, "before": before])
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            restoreRAWPreviewForConfiguration()
            // RAW Writer reads K from the same RAW samples. A second full-raster
            // data output exceeds the device's resource budget at 120 fps.
            if usesRAWWriterExperiment {
                if session.outputs.contains(intrinsicOutput) { session.removeOutput(intrinsicOutput) }
            } else if !session.outputs.contains(intrinsicOutput), session.canAddOutput(intrinsicOutput) {
                session.addOutput(intrinsicOutput)
            }
            logProVideoStorage("format_before_sensor_change")
            session.automaticallyConfiguresCaptureDeviceForWideColor = requestedColorSpace == .systemDefault
            try camera.lockForConfiguration()
            camera.activeFormat = info.format
            if let colorSpace = requestedColorSpace.captureColorSpace {
                camera.activeColorSpace = colorSpace
            } else if (reason == "color_space_change" || chosenRecordingColorSpace != .systemDefault),
                      info.format.supportedColorSpaces.contains(.sRGB) {
                // Returning from an explicit Log/HDR choice must not leave that
                // transfer function active under the "System Default" label.
                camera.activeColorSpace = .sRGB
            }
            let requestedFPS = CaptureFrameRatePolicy.normalized(chosenFPS)
            let targetFPS = availableFPS(for: info).contains(where: { abs($0 - requestedFPS) < 0.01 })
                ? requestedFPS : nearestFPS(to: requestedFPS, in: info)
            let duration = CMTime(value: 1_000_000, timescale: CMTimeScale((targetFPS * 1_000_000).rounded()))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
            guard (usesProResDataWriter || output.availableVideoCodecTypes.contains(codec)), let connection = output.connection(with: .video) else {
                throw CameraError.unavailableCodec(codec.rawValue, index)
            }
            enableIntrinsicDelivery()
            let settings = usesProResDataWriter ? [AVVideoCodecKey: AVVideoCodecType.hevc.rawValue] :
                try encodingSettings(for: info, fps: targetFPS, connection: connection)
            if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                self.output.setOutputSettings(settings, for: connection)
            }) { throw CameraError.unsupportedFocus("Encoding settings: \(exception)") }
            logProVideoStorage("format_after_encoder_change")
            try resetCameraControls(camera, fps: targetFPS, manualExposure: exposureToRestore)
            chosenIndex = index; chosenFPS = targetFPS
            chosenRecordingColorSpace = requestedColorSpace
            lutPreview.setExpectedColorSpace(requestedColorSpace)
            if !chosenEncoding.isRAW { configureLUTPreview() }
            persistCaptureConfiguration()
            if reason != "initial_selection" {
                let preferences = UserDefaults.standard
                preferences.set(codec.rawValue, forKey: "capture.codec.\(camera.uniqueID)")
                preferences.set(chosenEncoding.rawValue, forKey: "capture.encoding.\(camera.uniqueID)")
                preferences.set(index, forKey: "capture.format.\(camera.uniqueID)")
                preferences.set(targetFPS, forKey: "capture.fps.\(camera.uniqueID)")
            }
            logger.event("configuration_result", ["kind": reason, "success": true, "after": configurationSnapshot()])
            scheduleRAWPipelinePreparation()
            let telemetryEmbeddable = currentTelemetrySupport
            publish {
                self.selectedCodec = codec; self.selectedEncoding = self.chosenEncoding
                if self.chosenEncoding.isRAW { self.setLUTBurnEnabled(false) }
                self.selectedRecordingColorSpace = requestedColorSpace
                self.selectedFormatIndex = index; self.fps = targetFPS
                self.telemetryEmbeddable = telemetryEmbeddable
                self.isoRange = Double(camera.activeFormat.minISO)...Double(camera.activeFormat.maxISO)
                self.exposureRange = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)...CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
                self.errorText = nil
            }
            return true
        } catch {
            session.automaticallyConfiguresCaptureDeviceForWideColor = previousAutomaticWideColor
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = previousFormat
                if previousFormat.supportedColorSpaces.contains(previousColorSpace) {
                    camera.activeColorSpace = previousColorSpace
                }
                camera.activeVideoMinFrameDuration = previousMin
                camera.activeVideoMaxFrameDuration = previousMax
                camera.unlockForConfiguration()
            } catch { logger.event("configuration_rollback_error", ["error": String(describing: error)]) }
            logger.event("configuration_result", ["kind": reason, "success": false, "error": String(describing: error), "after": configurationSnapshot()])
            fail("Format configuration: \(error)")
            return false
        }
    }

    /// Preserve manual exposure across lens and FPS changes, respecting the new sensor's limits.
    private func resetCameraControls(_ camera: AVCaptureDevice, fps: Double,
                                     manualExposure: ManualExposurePreference? = nil) throws {
        try camera.lockForConfiguration()
        defer {
            applyWhiteBalancePreferenceLocked(camera)
            let bias = Float(min(max(exposureBiasIntent, max(-6, Double(camera.minExposureTargetBias))), min(6, Double(camera.maxExposureTargetBias))))
            camera.setExposureTargetBias(bias, completionHandler: nil)
            restoreFocusPreferenceLocked(camera)
            camera.unlockForConfiguration()
        }
        if let manualExposure, camera.isExposureModeSupported(.custom) {
            let duration = manualExposure.angle.map {
                CaptureDefaults.exposure(forShutterAngle: $0, fps: fps,
                    minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
                    maximum: camera.activeFormat.maxExposureDuration.seconds)
            } ?? CaptureDefaults.clampedManualExposure(manualExposure.seconds, fps: fps,
                minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
                maximum: camera.activeFormat.maxExposureDuration.seconds)
            let iso = Float(min(max(manualExposure.iso, Double(camera.activeFormat.minISO)),
                                Double(camera.activeFormat.maxISO)))
            camera.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                                         iso: iso)
            manualExposureIntent = manualExposure
            activeShutterAngle = manualExposure.angle
            if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
                camera.whiteBalanceMode = .continuousAutoWhiteBalance
            }
            if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
            chosenFocus = .continuous
            logger.event("manual_exposure_restored", ["fps": fps, "requestedSeconds": manualExposure.seconds,
                "exposureSeconds": duration, "requestedISO": manualExposure.iso, "iso": iso,
                "shutterAngle": manualExposure.angle as Any? ?? NSNull()])
            publish {
                self.shutterMode = manualExposure.angle == nil ? .manual : .angle
                if let angle = manualExposure.angle { self.shutterAngle = angle }
                self.exposureAuto = false
                self.whiteBalanceAuto = true; self.focusChoice = .continuous
            }
            return
        }
        activeShutterAngle = nil
        manualExposureIntent = nil
        let defaultLimit = CaptureDefaults.maximumExposure(fps: fps,
            minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
            maximum: camera.activeFormat.maxExposureDuration.seconds)
        let limit = CaptureDefaults.clampedManualExposure(savedControls.maximumSeconds ?? defaultLimit, fps: fps,
            minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
            maximum: camera.activeFormat.maxExposureDuration.seconds)
        if camera.isExposureModeSupported(.continuousAutoExposure) {
            camera.exposureMode = .continuousAutoExposure
            camera.activeMaxExposureDuration = savedControls.shutter == "auto" ? .invalid : CMTime(seconds: limit, preferredTimescale: 1_000_000)
        }
        if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        if camera.isFocusModeSupported(.continuousAutoFocus) { camera.focusMode = .continuousAutoFocus }
        shutterMaxCustomized = savedControls.maximumSeconds != nil
        chosenFocus = .continuous
        logger.event("control_defaults", ["fps": fps, "maxExposure": limit,
            "focusMode": focusName(camera.focusMode)])
        let restoredShutterMode: ShutterMode = savedControls.shutter == "auto" ? .auto : .autoMax
        publish {
            self.shutterMode = restoredShutterMode; self.shutterMaxSeconds = limit
            self.exposureAuto = true; self.whiteBalanceAuto = true; self.focusChoice = .continuous
        }
    }

    func chooseFPS(_ value: Double) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting, !self.captureFinishing else { self.fail("FPS cannot change during recording"); return }
            guard value.isFinite, value > 0, value <= CaptureFrameRatePolicy.maximum else {
                self.fail("FPS \(value) is disabled"); return
            }
            guard let camera = self.device, let index = self.chosenIndex,
                  self.formatObjects.indices.contains(index), let codec = self.chosenCodec else {
                self.fail("No active video format"); return
            }
            guard self.formatObjects.contains(where: {
                $0.compatibleCodecs.contains(codec.rawValue) &&
                $0.width == self.formatObjects[index].width && $0.height == self.formatObjects[index].height &&
                self.availableFPS(for: $0).contains(where: { abs($0 - value) < 0.01 })
            }) else { self.fail("FPS unavailable for this codec and resolution"); return }
            let preferredIndex = self.preferredIntrinsicFormatIndex(near: index, fps: value,
                                                                    codec: codec, in: self.formatObjects)
            if !self.formatObjects[index].supports(value) || preferredIndex != index {
                let current = self.formatObjects[index]
                let candidates = self.formatObjects.filter {
                    $0.width == current.width && $0.height == current.height &&
                    $0.compatibleCodecs.contains(codec.rawValue) &&
                    self.availableFPS(for: $0).contains(where: { abs($0 - value) < 0.01 })
                }
                guard let alternate = candidates.min(by: {
                    ($0.format.autoFocusSystem == .none ? 1 : 0,
                     $0.supportsIntrinsics ? 0 : 1,
                     $0.fourCC == "420v" ? 0 : 1,
                     abs($0.index - index)) <
                    ($1.format.autoFocusSystem == .none ? 1 : 0,
                     $1.supportsIntrinsics ? 0 : 1,
                     $1.fourCC == "420v" ? 0 : 1,
                     abs($1.index - index))
                }) else {
                    self.fail("FPS \(value) is unsupported at the selected resolution"); return
                }
                let previousFPS = self.chosenFPS
                self.chosenFPS = value
                if !self.applyFormat(alternate.index, reason: "fps_change") {
                    self.chosenFPS = previousFPS
                }
                return
            }
            if self.usesRAWWriterExperiment || self.usesProResDataWriter {
                let previous = self.chosenFPS
                self.chosenFPS = value
                if !self.applyFormat(index, reason: "fps_change") { self.chosenFPS = previous }
                return
            }
            let before = self.configurationSnapshot()
            let previousMin = camera.activeVideoMinFrameDuration
            let previousMax = camera.activeVideoMaxFrameDuration
            let manualExposure = self.manualExposurePreference(camera)
            self.logger.event("fps_request", ["requested": value, "before": before])
            do {
                try camera.lockForConfiguration()
                let duration = CMTime(value: 1_000_000, timescale: CMTimeScale((value * 1_000_000).rounded()))
                camera.activeVideoMinFrameDuration = duration; camera.activeVideoMaxFrameDuration = duration
                camera.unlockForConfiguration()
                guard let codec = self.chosenCodec, self.output.availableVideoCodecTypes.contains(codec) else {
                    try camera.lockForConfiguration()
                    camera.activeVideoMinFrameDuration = previousMin
                    camera.activeVideoMaxFrameDuration = previousMax
                    camera.unlockForConfiguration()
                    throw CameraError.unavailableCodec(self.chosenCodec?.rawValue ?? "none", index)
                }
                if let connection = self.output.connection(with: .video) {
                    let settings = try self.encodingSettings(for: self.formatObjects[index], fps: value, connection: connection)
                    if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                        self.output.setOutputSettings(settings, for: connection)
                    }) { throw CameraError.unsupportedFocus("Encoding settings: \(exception)") }
                }
                try self.resetCameraControls(camera, fps: value,
                                             manualExposure: manualExposure)
                self.chosenFPS = value
                self.persistCaptureConfiguration()
                UserDefaults.standard.set(value, forKey: "capture.fps.\(camera.uniqueID)")
                self.logger.event("fps_result", ["success": true, "after": self.configurationSnapshot()])
                self.scheduleRAWPipelinePreparation()
                self.publish { self.fps = value; self.errorText = nil }
            } catch {
                self.logger.event("fps_result", ["success": false, "error": String(describing: error), "after": self.configurationSnapshot()])
                self.fail("FPS configuration: \(error)")
            }
        }
    }

    private func nearestFPS(to requested: Double, in format: FormatInfo) -> Double {
        let rates = availableFPS(for: format)
        return rates.min { abs($0 - requested) < abs($1 - requested) } ?? 30
    }

    /// Keep the requested raster, frame rate, codec and autofocus capability.
    /// Some device formats differ only by pixel range/crop, while just one
    /// delivers measured K. Prefer video-range YUV when both deliver K.
    private func preferredIntrinsicFormatIndex(near index: Int, fps: Double,
                                               codec: AVVideoCodecType, in formats: [FormatInfo]) -> Int {
        guard formats.indices.contains(index), !formats[index].supportsIntrinsics else { return index }
        let current = formats[index]
        let options = formats.filter {
            $0.width == current.width && $0.height == current.height &&
            $0.supports(fps) && $0.compatibleCodecs.contains(codec.rawValue) &&
            $0.format.autoFocusSystem == current.format.autoFocusSystem && $0.supportsIntrinsics
        }
        return options.min {
            ($0.fourCC == "420v" ? 0 : 1,
             abs(Double($0.format.videoFieldOfView - current.format.videoFieldOfView)), $0.index) <
            ($1.fourCC == "420v" ? 0 : 1,
             abs(Double($1.format.videoFieldOfView - current.format.videoFieldOfView)), $1.index)
        }?.index ?? index
    }

    private func closestFormatIndex(in formats: [FormatInfo], codec: AVVideoCodecType,
                                    preference: CapturePreference) -> Int? {
        let targetArea = max(1.0, Double(preference.width) * Double(preference.height))
        let targetAspect = Double(preference.width) / Double(preference.height)
        func score(_ info: FormatInfo) -> Double {
            let area = max(1.0, Double(info.width) * Double(info.height))
            let aspect = Double(info.width) / Double(info.height)
            let fps = nearestFPS(to: preference.fps, in: info)
            return abs(log(area / targetArea)) * 100 + abs(aspect - targetAspect) * 60
                + abs(fps - preference.fps) * 2 + (info.format.autoFocusSystem == .none ? 200 : 0)
                + (info.supportsIntrinsics ? 0 : 10)
        }
        return formats.indices.filter {
            formats[$0].compatibleCodecs.contains(codec.rawValue) && !availableFPS(for: formats[$0]).isEmpty
        }
            .min { score(formats[$0]) < score(formats[$1]) }
    }

    private func encodingSettings(for info: FormatInfo, fps: Double, connection: AVCaptureConnection) throws -> [String: Any] {
        guard let codec = chosenCodec else { throw CameraError.unsupportedFocus("Video codec") }
        var settings: [String: Any] = [AVVideoCodecKey: codec.rawValue]
        if chosenEncoding == .hevcHQ || chosenEncoding == .hevc {
            guard output.supportedOutputSettingsKeys(for: connection).contains(AVVideoCompressionPropertiesKey) else {
                throw CameraError.unsupportedFocus("H.265 bitrate control")
            }
            let bitrate: Int
            if chosenEncoding == .hevcHQ {
                bitrate = Int(min(200_000_000, max(10_000_000,
                    Double(info.width) * Double(info.height) * fps * 0.35)))
            } else if let requested = chosenHEVCBitratePreset.targetBitsPerSecond(
                width: info.width, height: info.height, fps: fps) {
                bitrate = requested
            } else {
                throw CameraError.unsupportedFocus("Invalid H.265 bitrate target")
            }
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_AverageBitRate as String: bitrate]
        }
        return settings
    }

    private func availableFPS(for format: FormatInfo) -> [Double] {
        let rates = CaptureFrameRatePolicy.available(for: format)
        // A 4K/120 ProRes 422 switch reports codec availability, then fails
        // at session start with AVFoundation -11872 (hardware resources).
        return chosenEncoding.isProRes422 && format.width >= 3840
            ? rates.filter { $0 <= 60.01 } : rates
    }

    var availableFPS: [Double] {
        guard let index = selectedFormatIndex, formats.indices.contains(index),
              let codec = selectedCodec else { return [] }
        let current = formats[index]
        let matching = formats.filter {
            $0.width == current.width && $0.height == current.height &&
            $0.compatibleCodecs.contains(codec.rawValue)
        }
        return Array(Set(matching.flatMap(availableFPS(for:)))).sorted()
    }

    private func configurationSnapshot() -> [String: Any] {
        guard let camera = device else { return [:] }
        return ["selectedCodec": chosenCodec?.rawValue ?? "none", "selectedFormat": chosenIndex ?? -1,
                "selectedEncoding": chosenEncoding.title, "selectedFPS": chosenFPS,
                "selectedColorSpace": chosenRecordingColorSpace.rawValue,
                "activeColorSpace": camera.activeColorSpace.rawValue,
                "actualFormat": camera.formats.firstIndex(where: { $0 === camera.activeFormat }) ?? -1,
                "minFrameDurationSeconds": CMTimeGetSeconds(camera.activeVideoMinFrameDuration),
                "maxFrameDurationSeconds": CMTimeGetSeconds(camera.activeVideoMaxFrameDuration),
                "focusMode": focusName(camera.focusMode), "adjustingFocus": camera.isAdjustingFocus,
                "focusPoint": ["x": camera.focusPointOfInterest.x, "y": camera.focusPointOfInterest.y],
                "lensPosition": camera.lensPosition,
                "exposureMode": camera.exposureMode.rawValue, "exposureSeconds": camera.exposureDuration.seconds,
                "iso": camera.iso, "shutterAngle": activeShutterAngle as Any? ?? NSNull(),
                "requestedExposureSeconds": manualExposureIntent?.seconds as Any? ?? NSNull(),
                "requestedISO": manualExposureIntent?.iso as Any? ?? NSNull(),
                "whiteBalanceMode": camera.whiteBalanceMode.rawValue,
                "whiteBalanceChoice": chosenWhiteBalance.rawValue,
                "whiteBalanceGains": [camera.deviceWhiteBalanceGains.redGain, camera.deviceWhiteBalanceGains.greenGain, camera.deviceWhiteBalanceGains.blueGain],
                "exposureBias": camera.exposureTargetBias,
                "outputSettings": output.connection(with: .video).map { output.outputSettings(for: $0) } ?? [:]]
    }

    private func focusName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode { case .continuousAutoFocus: return "continuousAutoFocus"; case .autoFocus: return "autoFocus"; case .locked: return "locked"; @unknown default: return "unknown" }
    }

    private func restoreFocusPreferenceLocked(_ camera: AVCaptureDevice) {
        let choice = FocusChoice(rawValue: savedControls.focus) ?? .continuous
        let locked = choice == .manual || choice == .locked
        if camera.isFocusPointOfInterestSupported && (savedControls.focusX != 0.5 || savedControls.focusY != 0.5) {
            camera.focusPointOfInterest = CGPoint(x: min(1, max(0, savedControls.focusX)), y: min(1, max(0, savedControls.focusY)))
        }
        if locked && camera.isLockingFocusWithCustomLensPositionSupported {
            camera.setFocusModeLocked(lensPosition: min(1, max(0, savedControls.focusPosition)), completionHandler: nil)
            chosenFocus = choice
        } else if camera.isFocusModeSupported(.continuousAutoFocus) {
            if camera.focusMode != .continuousAutoFocus { camera.focusMode = .continuousAutoFocus }
            chosenFocus = .continuous
        }
        let restored = chosenFocus
        publish { self.focusChoice = restored }
    }

    func chooseFocus(_ choice: FocusChoice, point: CGPoint? = nil, manualPosition: Float? = nil) {
        queue.async {
            guard let camera = self.device else { return }
            let before = self.configurationSnapshot()
            self.logger.event("focus_command", ["choice": choice.rawValue, "point": point.map { ["x": $0.x, "y": $0.y] } ?? [:],
                                                "manualPosition": manualPosition as Any? ?? NSNull(), "before": before])
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let desired: AVCaptureDevice.FocusMode = switch choice {
                case .continuous: .continuousAutoFocus
                case .single, .tap: .autoFocus
                // A hold on the preview first focuses at that location. Apple's
                // single AF holds the resulting lens position after its scan.
                case .locked: point == nil ? .locked : .autoFocus
                case .manual: .locked
                }
                guard camera.isFocusModeSupported(desired) else { throw CameraError.unsupportedFocus(choice.rawValue) }
                if let point {
                    guard camera.isFocusPointOfInterestSupported else { throw CameraError.unsupportedFocus("focus point") }
                    camera.focusPointOfInterest = CGPoint(x: min(1, max(0, point.x)), y: min(1, max(0, point.y)))
                }
                if choice == .manual {
                    guard camera.isLockingFocusWithCustomLensPositionSupported else { throw CameraError.unsupportedFocus("manual lens position") }
                    camera.setFocusModeLocked(lensPosition: min(1, max(0, manualPosition ?? camera.lensPosition))) { [weak self] time in
                        guard let self else { return }
                        self.queue.async {
                            self.logger.event("manual_focus_completed", ["deviceTimeSeconds": CMTimeGetSeconds(time),
                                                                         "state": self.configurationSnapshot()])
                        }
                    }
                } else { camera.focusMode = desired }
                self.chosenFocus = choice
                self.savedControls.focus = choice.rawValue
                self.savedControls.focusPosition = min(1, max(0, manualPosition ?? camera.lensPosition))
                if let point { self.savedControls.focusX = point.x; self.savedControls.focusY = point.y }
                self.savedControls.save()
                self.logger.event("focus_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish { self.focusChoice = choice; self.errorText = nil }
            } catch {
                self.logger.event("focus_command_error", ["error": String(describing: error), "after": self.configurationSnapshot()])
                self.fail("Focus: \(error)")
            }
        }
    }

    func tapFocus(_ point: CGPoint) { chooseFocus(.continuous, point: point) }
    func lockFocus(at point: CGPoint) { chooseFocus(.locked, point: point) }
    func setManualPosition(_ value: Float) { chooseFocus(.manual, manualPosition: value) }
    func setExposureAuto(_ enabled: Bool) {
        queue.async {
            guard let camera = self.device else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if enabled {
                    guard camera.isExposureModeSupported(.continuousAutoExposure) else { throw CameraError.unsupportedFocus("Auto exposure") }
                    camera.activeMaxExposureDuration = .invalid
                    camera.exposureMode = .continuousAutoExposure
                    self.manualExposureIntent = nil
                } else {
                    guard camera.isExposureModeSupported(.custom) else { throw CameraError.unsupportedFocus("Manual exposure") }
                    camera.setExposureModeCustom(duration: camera.exposureDuration, iso: camera.iso)
                    self.manualExposureIntent = ManualExposurePreference(
                        seconds: camera.exposureDuration.seconds, iso: Double(camera.iso), angle: nil)
                }
                self.savedControls.shutter = enabled ? "auto" : "manual"
                if !enabled { self.savedControls.seconds = camera.exposureDuration.seconds; self.savedControls.iso = Double(camera.iso) }
                self.savedControls.save()
                let mode: ShutterMode = enabled ? .auto : .manual
                self.activeShutterAngle = nil
                self.publish { self.exposureAuto = enabled; self.shutterMode = mode }
            } catch { self.fail("Exposure: \(error)") }
        }
    }
    func activateExposureAutoMax(resetToDefault: Bool = false) {
        queue.async {
            guard let camera = self.device else { return }
            if resetToDefault { self.shutterMaxCustomized = false; self.savedControls.maximumSeconds = nil }
            let requested = self.shutterMaxCustomized ? self.shutterMaxSeconds :
                CaptureDefaults.maximumExposure(fps: self.chosenFPS,
                    minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
                    maximum: camera.activeFormat.maxExposureDuration.seconds)
            self.applyExposureAutoMax(seconds: requested, customized: false)
        }
    }
    func setExposureAutoMax(seconds: Double, customized: Bool = true) {
        queue.async {
            self.applyExposureAutoMax(seconds: seconds, customized: customized)
        }
    }
    private func applyExposureAutoMax(seconds: Double, customized: Bool) {
        guard let camera = device else { return }
        do {
            try camera.lockForConfiguration()
            defer { camera.unlockForConfiguration() }
            guard camera.isExposureModeSupported(.continuousAutoExposure) else {
                throw CameraError.unsupportedFocus("Auto exposure")
            }
            let minimum = max(CMTimeGetSeconds(camera.activeFormat.minExposureDuration), 1.0 / 8000)
            let maximum = min(CMTimeGetSeconds(camera.activeFormat.maxExposureDuration), 1 / chosenFPS)
            let limit = min(max(seconds, minimum), maximum)
            camera.exposureMode = .continuousAutoExposure
            camera.activeMaxExposureDuration = CMTime(seconds: limit, preferredTimescale: 1_000_000)
            activeShutterAngle = nil
            manualExposureIntent = nil
            if customized { shutterMaxCustomized = true; savedControls.maximumSeconds = limit }
            savedControls.shutter = "autoMax"
            savedControls.save()
            logger.event("exposure_auto_max", ["limitSeconds": limit, "state": configurationSnapshot()])
            publish {
                self.shutterMaxSeconds = limit; self.shutterMode = .autoMax; self.exposureAuto = true
            }
        } catch { fail("A-Max: \(error)") }
    }
    func setShutterAngle(_ angle: Double) {
        queue.async {
            guard let camera = self.device, camera.isExposureModeSupported(.custom) else {
                self.fail("Shutter angle is unavailable on this camera"); return
            }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let minimumAngle = max(1, 360 * max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000) * self.chosenFPS)
                let maximumAngle = min(360, 360 * camera.activeFormat.maxExposureDuration.seconds * self.chosenFPS)
                let requested = min(max(angle, minimumAngle), maximumAngle)
                let duration = CaptureDefaults.exposure(forShutterAngle: requested, fps: self.chosenFPS,
                    minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
                    maximum: camera.activeFormat.maxExposureDuration.seconds)
                let requestedISO = self.manualExposureIntent?.iso ?? Double(camera.iso)
                let iso = Float(min(max(requestedISO,
                                        Double(camera.activeFormat.minISO)), Double(camera.activeFormat.maxISO)))
                camera.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                                             iso: iso)
                self.activeShutterAngle = requested
                self.manualExposureIntent = ManualExposurePreference(seconds: duration, iso: requestedISO, angle: requested)
                self.savedControls.shutter = "angle"; self.savedControls.angle = requested
                self.savedControls.seconds = duration; self.savedControls.iso = requestedISO
                self.savedControls.save()
                self.logger.event("shutter_angle", ["angle": requested, "fps": self.chosenFPS,
                    "exposureSeconds": duration])
                self.publish {
                    self.shutterMode = .angle; self.shutterAngle = requested; self.exposureAuto = false
                }
            } catch { self.fail("Shutter angle: \(error)") }
        }
    }
    func setManualExposure(seconds: Double? = nil, iso: Double? = nil) {
        queue.async {
            guard let camera = self.device, camera.isExposureModeSupported(.custom) else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let upper = min(camera.activeFormat.maxExposureDuration, CMTime(seconds: 1 / self.chosenFPS, preferredTimescale: 1_000_000))
                let lower = max(camera.activeFormat.minExposureDuration, CMTime(value: 1, timescale: 8000))
                let range = lower...max(lower, upper)
                let requested = CMTime(seconds: seconds ?? self.activeShutterAngle.map {
                    CaptureDefaults.exposure(forShutterAngle: $0, fps: self.chosenFPS,
                        minimum: max(camera.activeFormat.minExposureDuration.seconds, 1.0 / 8000),
                        maximum: camera.activeFormat.maxExposureDuration.seconds)
                } ?? self.manualExposureIntent?.seconds ?? CMTimeGetSeconds(camera.exposureDuration), preferredTimescale: 1_000_000)
                let duration = min(max(requested, range.lowerBound), range.upperBound)
                let requestedISO = iso ?? self.manualExposureIntent?.iso ?? Double(camera.iso)
                let retainedAngle = seconds == nil ? self.activeShutterAngle : nil
                let level = Float(min(max(requestedISO,
                                          Double(camera.activeFormat.minISO)), Double(camera.activeFormat.maxISO)))
                camera.setExposureModeCustom(duration: duration, iso: level)
                self.activeShutterAngle = retainedAngle
                self.manualExposureIntent = ManualExposurePreference(seconds: requested.seconds, iso: requestedISO, angle: retainedAngle)
                self.savedControls.shutter = retainedAngle == nil ? "manual" : "angle"
                self.savedControls.seconds = requested.seconds; self.savedControls.iso = requestedISO
                if let retainedAngle { self.savedControls.angle = retainedAngle }
                self.savedControls.save()
                self.logger.event("manual_exposure_set", ["state": self.configurationSnapshot()])
                self.publish { self.exposureAuto = false; self.shutterMode = retainedAngle == nil ? .manual : .angle }
            } catch { self.fail("Exposure: \(error)") }
        }
    }
    private func applyWhiteBalancePreferenceLocked(_ camera: AVCaptureDevice) {
        let raw = chosenCodec?.rawValue == "aprn" || chosenCodec?.rawValue == "aprh"
        if raw || chosenWhiteBalance == .manual || autoLockWhiteBalanceActive {
            guard camera.isWhiteBalanceModeSupported(.locked) else { return }
            if let kelvin = manualWhiteBalanceKelvin, chosenWhiteBalance == .manual {
                let gains = camera.deviceWhiteBalanceGains(for: .init(temperature: kelvin, tint: 0))
                let ceiling = camera.maxWhiteBalanceGain
                camera.setWhiteBalanceModeLocked(with: .init(redGain: min(max(gains.redGain, 1), ceiling),
                    greenGain: min(max(gains.greenGain, 1), ceiling), blueGain: min(max(gains.blueGain, 1), ceiling)))
            } else { camera.whiteBalanceMode = .locked }
        } else if camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            camera.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        let automatic = camera.whiteBalanceMode == .continuousAutoWhiteBalance
        let choice = raw ? WhiteBalanceChoice.manual : chosenWhiteBalance
        publish { self.whiteBalanceAuto = automatic; self.whiteBalanceChoice = choice }
    }
    func setWhiteBalanceAuto(_ enabled: Bool) { setWhiteBalanceChoice(enabled ? .auto : .manual) }
    func setWhiteBalanceChoice(_ choice: WhiteBalanceChoice) {
        queue.async {
            guard let camera = self.device else { return }
            if choice != .manual &&
                (self.chosenCodec?.rawValue == "aprn" || self.chosenCodec?.rawValue == "aprh") {
                self.fail("RAW 拍摄需要保持白平衡锁定"); return
            }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                self.chosenWhiteBalance = choice
                self.restoreAutoWhiteBalanceAfterRecording = false
                self.autoLockWhiteBalanceActive = choice == .autoLock && (self.output.isRecording || self.realtimeLUTWriter != nil)
                if choice == .manual && self.manualWhiteBalanceKelvin == nil {
                    self.manualWhiteBalanceKelvin = min(max(self.whiteBalanceKelvin, 2500), 10000)
                }
                self.applyWhiteBalancePreferenceLocked(camera)
                self.savedControls.whiteBalance = choice.rawValue; self.savedControls.kelvin = self.manualWhiteBalanceKelvin
                self.savedControls.save()
                self.logger.event("white_balance_choice", ["choice": choice.rawValue, "state": self.configurationSnapshot()])
            } catch { self.fail("White balance: \(error)") }
        }
    }
    func setRulerHaptics(_ enabled: Bool) {
        queue.async { self.applyRulerHaptics(enabled) }
    }
    private func applyRulerHaptics(_ enabled: Bool) {
        // Audio input suppresses haptics by default, including camera preview.
        do {
            let audio = AVAudioSession.sharedInstance()
            try audio.setAllowHapticsAndSystemSoundsDuringRecording(enabled)
            logger.event("ruler_haptics", ["requested": enabled,
                "allowedWithAudioInput": audio.allowHapticsAndSystemSoundsDuringRecording])
        } catch { logger.event("ruler_haptics_error", ["error": error.localizedDescription]) }
    }
    func setExposureBias(_ value: Double) {
        queue.async {
            guard let camera = self.device else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                self.exposureBiasIntent = min(max(value, -6), 6)
                let bias = Float(min(max(self.exposureBiasIntent, max(-6, Double(camera.minExposureTargetBias))), min(6, Double(camera.maxExposureTargetBias))))
                camera.setExposureTargetBias(bias, completionHandler: nil)
                self.publish { self.exposureBias = Double(bias) }
                self.savedControls.ev = self.exposureBiasIntent; self.savedControls.save()
                self.logger.event("exposure_bias", ["bias": bias, "state": self.configurationSnapshot()])
            } catch { self.fail("Exposure compensation: \(error)") }
        }
    }
    func setWhiteBalance(kelvin: Float) {
        queue.async {
            guard let camera = self.device, camera.isWhiteBalanceModeSupported(.locked) else { return }
            self.restoreAutoWhiteBalanceAfterRecording = false
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let temperature = min(max(kelvin, 2500), 10000)
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: temperature, tint: 0)
                let gains = camera.deviceWhiteBalanceGains(for: values)
                let ceiling = camera.maxWhiteBalanceGain
                let safe = AVCaptureDevice.WhiteBalanceGains(redGain: min(max(gains.redGain, 1), ceiling),
                    greenGain: min(max(gains.greenGain, 1), ceiling), blueGain: min(max(gains.blueGain, 1), ceiling))
                camera.setWhiteBalanceModeLocked(with: safe)
                self.chosenWhiteBalance = .manual
                self.manualWhiteBalanceKelvin = temperature
                self.autoLockWhiteBalanceActive = false
                self.publish { self.whiteBalanceChoice = .manual }
                self.savedControls.whiteBalance = WhiteBalanceChoice.manual.rawValue; self.savedControls.kelvin = temperature
                self.savedControls.save()
                self.logger.event("white_balance_manual", ["kelvin": temperature, "tint": 0])
                self.publish { self.whiteBalanceAuto = false; self.whiteBalanceKelvin = temperature }
            } catch { self.fail("White balance: \(error)") }
        }
    }
    func mark() { queue.async { self.logger.event("mark", ["state": self.configurationSnapshot(), "recording": self.output.isRecording]) } }

    /// Serialize destructive library operations with capture and metadata commits.
    func deleteMedia(_ urls: [URL], completion: @escaping (String?) -> Void) {
        queue.async {
            guard !self.output.isRecording, !self.isRAWWriterActive, !self.recordingStarting, !self.captureFinishing else {
                self.publish { completion("录制尚未结束") }; return
            }
            var errors: [String] = []
            let freeBefore = self.localFreeBytes()
            let filesystemFreeBefore = (try? FileManager.default.attributesOfFileSystem(forPath: RecordingStoragePaths.movieDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value
            var deletedBytes: Int64 = 0
            var deletedLocalMovie = false
            for url in urls {
                do {
                    let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    try Self.removeMediaFiles(url)
                    deletedBytes += Int64(size)
                    if let bookmarks = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] {
                        let kept = bookmarks.filter { bookmark in
                            var stale = false
                            return (try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil,
                                             bookmarkDataIsStale: &stale))?.path != url.path
                        }
                        UserDefaults.standard.set(kept, forKey: "externalMediaBookmarks")
                    }
                } catch { errors.append(error.localizedDescription) }
                if url.deletingLastPathComponent().resolvingSymlinksInPath() == RecordingStoragePaths.movieDirectory.resolvingSymlinksInPath(),
                   !FileManager.default.fileExists(atPath: url.path) { deletedLocalMovie = true }
            }
            self.logger.event("media_deleted", ["deletedBytes": deletedBytes,
                "localFreeBefore": freeBefore ?? -1, "localFreeAfter": self.localFreeBytes() ?? -1,
                "filesystemFreeBefore": filesystemFreeBefore ?? -1,
                "filesystemFreeAfter": (try? FileManager.default.attributesOfFileSystem(forPath: RecordingStoragePaths.movieDirectory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? -1,
                "errors": errors, "storageLocation": UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件"])
            if deletedLocalMovie && ProVideoStorageBridge.isSupported() {
                self.storageReplenishPending = true
                self.storageReplenishFromDeletion = true
                self.storageReplenishRetries = 0
                self.storageReplenishNotBefore = 0
                self.replenishDeletedVideoStorageIfPossible()
            }
            self.refreshStorageBudget()
            self.publish { completion(errors.isEmpty ? nil : errors.joined(separator: "\n")) }
        }
    }

    static func removeMediaFiles(_ movie: URL) throws {
        guard movie.pathExtension.lowercased() == "mov" else { throw RecorderError.unavailable("Invalid media file") }
        // Delete the movie first: on failure retain the recovery material.
        try FileManager.default.removeItem(at: movie)
        let base = movie.deletingPathExtension()
        let local = RecordingStoragePaths.diagnosticDirectory
            .appendingPathComponent(base.lastPathComponent)
        let legacy = RecordingStoragePaths.legacyDirectory
            .appendingPathComponent(base.lastPathComponent)
        for file in [movie.appendingPathExtension("pending-imu.json"),
                     movie.appendingPathExtension("failed-imu.json"),
                     MOVTelemetryMuxer.recoveryURL(movie),
                     base.appendingPathExtension("imu_raw.jsonl"),
                     base.appendingPathExtension("camera_frames.jsonl"),
                     local.appendingPathExtension("pending-imu.json"),
                     local.appendingPathExtension("mov.pending-imu.json"),
                     local.appendingPathExtension("mov.failed-imu.json"),
                     local.appendingPathExtension("imu_raw.jsonl"),
                     local.appendingPathExtension("camera_frames.jsonl"),
                     legacy.appendingPathExtension("pending-imu.json"),
                     legacy.appendingPathExtension("mov.pending-imu.json"),
                     legacy.appendingPathExtension("mov.failed-imu.json"),
                     legacy.appendingPathExtension("imu_raw.jsonl"),
                     legacy.appendingPathExtension("camera_frames.jsonl"),
                     movie.appendingPathExtension("metadata-recovery.json")] {
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    private func restoreRAWPreviewForConfiguration() {
        lutPreview.reset()
        publish { self.lutSupported = false }
        if session.outputs.contains(lutPreview.output) { session.removeOutput(lutPreview.output) }
        if #available(iOS 27.0, *), let preview = rawWriterPreview as? RAWWriterPreview {
            preview.invalidate()
            if session.outputs.contains(preview.dataOutput) { session.removeOutput(preview.dataOutput) }
            if session.outputs.contains(preview.audioOutput) { session.removeOutput(preview.audioOutput) }
            if !session.outputs.contains(output), session.canAddOutput(output) { session.addOutput(output) }
            rawWriterPreview = nil
        }
    }

    @available(iOS 27.0, *)
    private func prepareRAWWriterPreview() {
        guard usesRAWWriterExperiment, rawWriterPreview == nil, rawWriterExperiment == nil,
              let camera = device else { return }
        let preview = RAWWriterPreview(camera: camera, queue: queue,
            log: { [weak self] name, details in self?.logger.event(name, details) },
            completion: { [weak self] error in
                guard let self else { return }
                if let error {
                    self.recordingStarting = false; self.rawWriterStartRequested = false
                    // A failed preview must not remain cached and block every later REC.
                    self.session.stopRunning()
                    self.session.beginConfiguration()
                    self.restoreRAWPreviewForConfiguration()
                    self.session.commitConfiguration()
                    self.session.startRunning()
                    self.fail(error.localizedDescription); return
                }
                self.publish { self.whiteBalanceAuto = false; self.status = "Camera ready"; self.cameraReady = true }
                if self.rawWriterStartRequested {
                    self.rawWriterStartRequested = false; self.recordingStarting = false
                    self.startRAWWriterExperiment()
                }
            })
        rawWriterPreview = preview
        session.stopRunning()
        session.beginConfiguration()
        if session.outputs.contains(output) { session.removeOutput(output) }
        if session.outputs.contains(intrinsicOutput) { session.removeOutput(intrinsicOutput) }
        guard session.canAddOutput(preview.dataOutput) else {
            session.addOutput(output); session.commitConfiguration(); session.startRunning()
            rawWriterPreview = nil; fail("无法准备 RAW 输出"); return
        }
        session.addOutput(preview.dataOutput)
        guard session.canAddOutput(preview.audioOutput) else {
            session.removeOutput(preview.dataOutput); session.addOutput(output)
            session.commitConfiguration(); session.startRunning()
            rawWriterPreview = nil; fail("无法准备音频输出"); return
        }
        session.addOutput(preview.audioOutput)
        preview.configure()
        configureLUTPreview()
        let supportsK = preview.dataOutput.connection(with: .video)?.isCameraIntrinsicMatrixDeliveryEnabled ?? false
        nativeRAWKSupport[nativeRAWKKey] = supportsK
        publish { self.telemetryEmbeddable = supportsK; self.status = "正在准备 RAW 预览" }
        session.commitConfiguration()
        session.startRunning()
    }

    #if DEBUG
    private func runSSDSpeedTestWhenIdle(deadline: Double) {
        guard ProcessInfo.processInfo.systemUptime < deadline else { logger.event("ssd_speed_smoke_timeout"); return }
        guard !captureFinishing, !recordingStarting, !storageReplenishPending else {
            queue.asyncAfter(deadline: .now() + 1) { self.runSSDSpeedTestWhenIdle(deadline: deadline) }; return
        }
        startSSDSpeedTest()
    }

    private func runRAWWriterIntegratedSmoke() {
        let targetType: AVCaptureDevice.DeviceType = ProcessInfo.processInfo.arguments.contains("--writer-ultrawide")
            ? .builtInUltraWideCamera : (ProcessInfo.processInfo.arguments.contains("--writer-telephoto")
                ? .builtInTelephotoCamera : .builtInWideAngleCamera)
        guard let wide = lensDevices.values.first(where: { $0.deviceType == targetType }) else {
            logger.event("raw_writer_missing_lens", ["requested": targetType.rawValue]); return
        }
        if device?.uniqueID != wide.uniqueID {
            chooseLens(wide.uniqueID)
            queue.asyncAfter(deadline: .now() + 2) { self.runRAWWriterIntegratedSmoke() }
            return
        }
        if storageReplenishPending || captureFinishing {
            replenishDeletedVideoStorageIfPossible()
            queue.asyncAfter(deadline: .now() + 1) { self.runRAWWriterIntegratedSmoke() }
            return
        }
        let encoding: VideoEncoding = ProcessInfo.processInfo.arguments.contains("--writer-hq") ? .proResRAWHQ : .proResRAW
        let rate: Double = ProcessInfo.processInfo.arguments.contains("--writer-120") ? 120 :
            ProcessInfo.processInfo.arguments.contains("--writer-60") ? 60 : 30
        let height = ProcessInfo.processInfo.arguments.contains("--writer-opengate") ? 3024 : 2240
        guard let format = formatObjects.first(where: {
            $0.width == 4224 && $0.height == height && $0.supports(rate) && $0.compatibleCodecs.contains(encoding.codec.rawValue)
        }) else {
            logger.event("raw_writer_no_format", ["camera": device?.localizedName ?? "none",
                "width": 4224, "height": height, "fps": rate, "codec": encoding.codec.rawValue,
                "rawFormats": formatObjects.filter { $0.compatibleCodecs.contains(encoding.codec.rawValue) }
                    .map { ["index": $0.index, "width": $0.width, "height": $0.height,
                            "fps": [30.0, 60.0, 120.0].filter($0.supports)] as [String: Any] }])
            return
        }
        logger.event("raw_writer_matrix_case", ["camera": wide.localizedName, "deviceID": wide.uniqueID,
            "width": format.width, "height": format.height, "fps": rate, "codec": encoding.codec.rawValue])
        chosenEncoding = encoding; chosenCodec = encoding.codec; chosenFPS = rate
        let invalidStorageTest = ProcessInfo.processInfo.arguments.contains("--writer-invalid-internal")
        UserDefaults.standard.set(invalidStorageTest ? "内部文件" : (ProcessInfo.processInfo.arguments.contains("--writer-ssd") ? "外部 SSD" : "专用视频存储"), forKey: "storageLocation")
        guard applyFormat(format.index, reason: "raw_writer_experiment") else { return }
        if invalidStorageTest {
            queue.asyncAfter(deadline: .now() + 5) {
                var previewReady = false
                if #available(iOS 27.0, *) { previewReady = (self.rawWriterPreview as? RAWWriterPreview)?.ready ?? false }
                self.logger.event("raw_internal_guard_probe", ["running": self.session.isRunning,
                    "previewReady": previewReady,
                    "fps": self.chosenFPS, "writerRoute": self.usesRAWWriterExperiment])
                self.toggleRecording()
                self.queue.asyncAfter(deadline: .now() + 1) {
                    self.chooseEncoding(.hevc)
                    self.chooseFPS(60)
                    self.queue.asyncAfter(deadline: .now() + 3) {
                        self.logger.event("raw_internal_guard_recovery", ["running": self.session.isRunning,
                            "codec": self.chosenCodec?.rawValue ?? "", "fps": self.chosenFPS,
                            "writerActive": self.isRAWWriterActive])
                    }
                }
            }
            return
        }
        UserDefaults.standard.set(ProcessInfo.processInfo.arguments.contains("--writer-proto") ? "GyroflowProto" : "SonyMov", forKey: "outputFormat")
        startSmokeRecordingWhenReady(deadline: ProcessInfo.processInfo.systemUptime + 20)
    }

    #endif

    @available(iOS 27.0, *)
    private func startRAWWriterExperiment() {
        recordingLUTBurn = nil
        guard !recordingStarting, !captureFinishing, !output.isRecording,
              let camera = device, let codec = chosenCodec else { return }
        let storage = UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件"
        guard ["专用视频存储", "外部 SSD"].contains(storage) else {
            logger.event("raw_record_storage_rejected", ["storage": storage, "fps": chosenFPS])
            failStorage("ProRes RAW 需要专用视频存储或外部 SSD。请在设置中选择存储位置。")
            return
        }
        let dedicatedStorage = storage == "专用视频存储"
        if dedicatedStorage {
            guard ProVideoStorageBridge.isSupported(), ProVideoStorageBridge.remainingCapacity() > 0,
                  !ProVideoStorageBridge.isBusy() else { failStorage("请先配置可用的专用视频存储"); return }
        }
        guard audioReady else { fail("录制需要麦克风权限"); return }
        guard let preview = rawWriterPreview as? RAWWriterPreview, preview.ready else {
            rawWriterStartRequested = true; recordingStarting = true
            publish { self.status = "等待 RAW 预览就绪" }
            prepareRAWWriterPreview()
            return
        }
        guard storagePreflight() else { return }
        let url: URL
        do {
            #if DEBUG
            let testName = (ProcessInfo.processInfo.arguments.contains("--raw-writer-integrated-auto") ||
                ProcessInfo.processInfo.arguments.contains("--ui-testing")) &&
                !ProcessInfo.processInfo.arguments.contains("--writer-normal-name")
                ? "UITEST_IMG_writer_\(UUID().uuidString)" : ""
            #else
            let testName = ""
            #endif
            let destination = try movieDestination(localDirectory: RecordingStoragePaths.movieDirectory, baseName: testName)
            url = destination.0
            activeExternalMovieURL = destination.1 ? url : nil
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--ssd-matrix") { rawSmokeMovieName = url.lastPathComponent }
            #endif
        } catch { failStorage(error.localizedDescription); return }
        let directory = logger.sessionURL.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let imu = IMURecorder()
        do { try imu.start(at: directory.appendingPathComponent(base + ".imu_raw.jsonl")) }
        catch { releaseExternalMovieAccess(); fail("IMU 启动失败：\(error.localizedDescription)"); return }
        imuRecorder = imu
        intrinsicURL = directory.appendingPathComponent(base + ".camera_frames.jsonl")
        intrinsicsUnavailableReason = nil
        movieFirstFrameHost = nil
        recordingLens = camera.localizedName
        recordingOrientation = gravityMonitor.snapshot().orientation
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--writer-portrait") { recordingOrientation = .portrait }
        if ProcessInfo.processInfo.arguments.contains("--writer-landscape") { recordingOrientation = .landscapeRight }
        #endif
        currentFile = url
        recordingTimeSource = "Regular RAW presentation grid with per-frame original VideoDataOutput capture-time mapping; optical sync unverified"
        recordingStarting = true
        captureFinishing = true // Block lens/spec changes for the entire experimental capture.
        publish { self.status = "准备 RAW 录制" }
        let recordingClock = session.synchronizationClock
        let experiment = RAWInternalWriterExperiment(camera: camera, codec: codec, url: url, queue: queue,
            preview: preview, dedicatedStorage: dedicatedStorage, slateMetadata: recordingSlate.metadata,
            prepareRecovery: { [weak self] in
                guard let self, self.activeExternalMovieURL != nil else { return }
                let start = ProcessInfo.processInfo.systemUptime
                self.activeExternalMovieBookmark = try url.bookmarkData(options: .minimalBookmark,
                    includingResourceValuesForKeys: nil, relativeTo: nil)
                if let bookmark = self.activeExternalMovieBookmark {
                    var known = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] ?? []
                    if !known.contains(bookmark) { known.append(bookmark) }
                    UserDefaults.standard.set(known, forKey: "externalMediaBookmarks")
                }
                self.logger.event("raw_writer_recovery_prepared", ["milliseconds":
                    (ProcessInfo.processInfo.systemUptime - start) * 1000])
            }, orientation: recordingOrientation,
            imuReady: {
                guard let gyro = imu.firstGyroTime, let accel = imu.firstAccelTime else { return false }
                return ProcessInfo.processInfo.systemUptime - max(gyro, accel) >= 0.07
            }, metadata: { [weak self] sample, presentationTime in
                guard let self else { return }
                self.intrinsicRecorder.recordNativeMetadata(sample, clock: recordingClock, camera: camera,
                    presentationTime: presentationTime)
            }, log: { [weak self] name, details in
                self?.logger.event(name, details)
                if name == "raw_writer_finished", let dropped = details["captureDrops"] as? Int, dropped > 0 {
                    self?.recordingCadenceWarning = "录制丢帧 \(dropped) 帧，请检查画面"
                }
            },
            started: { [weak self] pts in
                guard let self else { return }
                self.fileOutput(self.output, didStartRecordingTo: url, startPTS: pts, from: [])
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--raw-writer-integrated-auto") {
                    let requestedDuration = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--writer-duration=") }
                        .flatMap { Double($0.dropFirst("--writer-duration=".count)) }
                    let duration = min(600, max(1, requestedDuration ?? (ProcessInfo.processInfo.arguments.contains("--writer-short") ? 5 : 10)))
                    self.queue.asyncAfter(deadline: .now() + duration) {
                        guard self.currentFile == url, self.rawWriterExperiment != nil else { return }
                        self.toggleRecording()
                    }
                }
                #endif
            }, finished: { [weak self] error in
                guard let self else { return }
                // Flush only metadata from frames actually delivered to this recorder.
                // Do not mix in restored preview/K callbacks after recording.
                do { try self.intrinsicRecorder.stop() }
                catch { self.logger.event("raw_writer_k_stop_error", ["error": String(describing: error)]) }
                preview.resume()
                self.rawWriterExperiment = nil
                self.recordingStarting = false
                self.fileOutput(self.output, didFinishRecordingTo: url, from: [], error: error)
            })
        rawWriterExperiment = experiment
        do { try intrinsicRecorder.start(at: intrinsicURL!, clock: session.synchronizationClock, camera: camera) }
        catch { experiment.stop(); fail("内参记录启动失败：\(error.localizedDescription)"); return }
        experiment.arm()
    }

    func toggleRecording() {
        queue.async {
            if let writer = self.realtimeLUTWriter {
                self.publish { self.finalizing = true }
                writer.stop(); return
            }
            if #available(iOS 27.0, *), let experiment = self.rawWriterExperiment as? RAWInternalWriterExperiment {
                self.publish { self.finalizing = true }
                experiment.stop()
                return
            }
            if #available(iOS 27.0, *),
               self.usesRAWWriterExperiment {
                self.startRAWWriterExperiment()
                return
            }
            if self.output.isRecording {
                self.logger.event("record_stop_request", ["state": self.configurationSnapshot()])
                self.publish { self.finalizing = true }
                if let exception = RecordingExceptionCatcher.exceptionMessage(for: { self.output.stopRecording() }) {
                    self.logger.event("record_stop_exception", ["message": exception])
                    self.publish { self.finalizing = false }
                    self.fail("Stop recording: \(exception)")
                }
                return
            }
            if self.rawStartWaiting { return }
            if self.recordingStarting || self.captureFinishing {
                self.logger.event("record_start_pending")
                return
            }
            if (self.chosenEncoding.isRAW ||
                (self.chosenEncoding.isProRes422 && ProVideoStorageBridge.isOutputSupported(self.output))),
               (UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件") == "内部文件" {
                self.failStorage("ProRes 录制需要专用视频存储或外部 SSD。请在设置中选择存储位置。")
                return
            }
            do {
                self.recordingLUTBurn = try LUTBurnRecipe.snapshot(encoding: self.chosenEncoding,
                    profile: self.chosenRecordingColorSpace, directory: self.logger.sessionURL.deletingLastPathComponent())
            } catch { self.fail(error.localizedDescription); return }
            guard self.storagePreflight() else { return }
            guard self.session.isRunning else { self.fail("Camera session is not running"); return }
            guard self.audioReady else { self.fail("需要麦克风权限才能录制声音。请在系统设置中允许麦克风访问。"); return }
            guard let codec = self.chosenCodec, let index = self.chosenIndex,
                  self.formatObjects[index].compatibleCodecs.contains(codec.rawValue),
                  (self.usesProResDataWriter || self.output.availableVideoCodecTypes.contains(codec)) else {
                self.fail("当前视频配置暂不可用，请在设置中重新选择编码、分辨率和帧率。"); return
            }
            if codec.rawValue != "aprn" && codec.rawValue != "aprh" {
                do { try self.prepareRAWWhiteBalance() }
                catch { self.fail("无法锁定白平衡，请重试。"); return }
            }
            if self.currentRAWSignature != nil {
                if self.rawPreparedSignature != self.currentRAWSignature {
                    do { try self.prepareRAWRecordingPipeline() }
                    catch { self.restoreRAWWhiteBalance(); self.fail(error.localizedDescription); return }
                }
                let delay = self.rawPipelineReadyAt - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    self.rawStartWaiting = true
                    self.recordingStarting = true
                    self.logger.event("raw_pipeline_wait", ["seconds": delay])
                    self.queue.asyncAfter(deadline: .now() + delay) {
                        self.rawStartWaiting = false
                        self.recordingStarting = false
                        guard self.canFinalizeNow else {
                            self.restoreRAWWhiteBalance()
                            self.fail("RAW 录制已取消：App 不在前台")
                            return
                        }
                        self.toggleRecording()
                    }
                    return
                }
            }
            let direction = self.gravityMonitor.snapshot()
            guard let connection = self.output.connection(with: .video),
                  connection.isVideoRotationAngleSupported(CGFloat(direction.orientation.degrees)) else {
                self.restoreRAWWhiteBalance()
                self.fail("相机不支持当前重力方向"); return
            }
            self.logProVideoStorage("record_before_rotation")
            connection.videoRotationAngle = CGFloat(direction.orientation.degrees)
            self.logProVideoStorage("record_after_rotation")
            self.recordingOrientation = direction.orientation
            self.logger.event("recording_direction", ["degrees": direction.orientation.degrees,
                "source": direction.source, "gravityX": direction.gravity?.x ?? 0,
                "gravityY": direction.gravity?.y ?? 0, "gravityZ": direction.gravity?.z ?? 0])
            let directory = self.logger.sessionURL.deletingLastPathComponent()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            let arguments = ProcessInfo.processInfo.arguments
            let isTest = arguments.contains("--ui-testing") || arguments.contains("--raw-ssd-smoke") ||
                arguments.contains("--hevc-4k60-smoke") || arguments.contains("--imu-sync-4k60-probe") ||
                arguments.contains("--first-buffer-probe") ||
                arguments.contains("--hevc-1080p120-smoke") ||
                arguments.contains("--raw-hq-ssd-smoke") || arguments.contains("--raw-long-hq-ssd-smoke") ||
                arguments.contains("--raw-hotplug-smoke") ||
                arguments.contains(where: { $0.hasPrefix("--prores422-smoke=") })
            let baseName = isTest && !arguments.contains("--slate-smoke") ? "UITEST_IMG_\(formatter.string(from: Date()))" : ""
            let storageLocation = UserDefaults.standard.string(forKey: "storageLocation") ?? "内部文件"
            if (self.chosenEncoding.isRAW ||
                (self.chosenEncoding.isProRes422 && ProVideoStorageBridge.isOutputSupported(self.output))),
               storageLocation != "外部 SSD", storageLocation != "专用视频存储" {
                self.restoreRAWWhiteBalance()
                self.failStorage("ProRes 请在设置中选择专用视频存储或外部 SSD")
                return
            }
            if storageLocation == "专用视频存储" {
                guard ProVideoStorageBridge.isSupported() else {
                    self.restoreRAWWhiteBalance()
                    self.failStorage("此设备或 iOS 版本不支持专用视频存储，请选择外部 SSD")
                    return
                }
                guard ProVideoStorageBridge.remainingCapacity() > 0 else {
                    self.restoreRAWWhiteBalance()
                    self.failStorage("专用视频存储未分配或空间已用完，请在设置中配置容量或选择外部 SSD")
                    return
                }
                guard !ProVideoStorageBridge.isBusy() else {
                    self.restoreRAWWhiteBalance()
                    self.failStorage("专用视频存储正在处理文件，请稍后重试")
                    return
                }
            }
            if let message = ProVideoStorageBridge.configureOutput(self.output,
                enabled: storageLocation == "专用视频存储" && !self.usesProResDataWriter) {
                self.restoreRAWWhiteBalance()
                self.logProVideoStorage("record_storage_rejected")
                let supported = ProVideoStorageBridge.isOutputSupported(self.output)
                let format = self.device.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }
                let size = format.map { "\($0.width)×\($0.height)" } ?? "unknown"
                self.failStorage("\(message)\n\(codec.rawValue) · \(size) · \(self.chosenFPS) fps\n设备支持：\(ProVideoStorageBridge.isSupported())\n录制输出支持：\(supported)\n剩余容量：\(ProVideoStorageBridge.remainingCapacity() / 1_000_000_000) GB\n诊断已保存到 Log")
                return
            }
            self.logger.event("record_storage_selected", ["location": storageLocation,
                "proVideoStorageSupported": ProVideoStorageBridge.isOutputSupported(self.output),
                "proVideoStorageRemainingBytes": storageLocation == "专用视频存储" ?
                    ProVideoStorageBridge.remainingCapacity() : 0])
            let url: URL
            do {
                let external: Bool
                (url, external) = try self.movieDestination(localDirectory: RecordingStoragePaths.movieDirectory,
                                                            baseName: baseName)
                self.activeExternalMovieURL = external ? url : nil
            } catch {
                self.restoreRAWWhiteBalance()
                let message = error.localizedDescription
                self.failStorage(message, retryOnReconnect: message.contains("未检测到已选择的外部 SSD"))
                return
            }
            #if DEBUG
            if arguments.contains("--raw-ssd-smoke") || arguments.contains("--raw-hq-ssd-smoke") ||
               arguments.contains("--raw-long-hq-ssd-smoke") ||
               arguments.contains("--raw-hotplug-smoke") ||
               arguments.contains("--hevc-4k60-smoke") || arguments.contains("--imu-sync-4k60-probe") ||
               arguments.contains("--first-buffer-probe") ||
               arguments.contains("--hevc-1080p120-smoke") ||
               arguments.contains(where: { $0.hasPrefix("--prores422-smoke=") }) {
                self.rawSmokeMovieName = url.lastPathComponent
            }
            #endif
            self.currentFile = url
            self.recordingTimeSource = nil
            let imu = IMURecorder()
            let imuURL = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".imu_raw.jsonl")
            do { try imu.start(at: imuURL) }
            catch {
                self.releaseExternalMovieAccess(); self.restoreRAWWhiteBalance()
                self.fail("IMU 启动失败：\(error.localizedDescription)"); return
            }
            self.imuRecorder = imu
            self.movieFirstFrameHost = nil
            self.intrinsicURL = nil
            self.intrinsicsUnavailableReason = nil
            do {
                let dc = self.intrinsicOutput.connection(with: .video)
                let mc = self.output.connection(with: .video)
                self.logger.event("intrinsic_configuration", ["supported": dc?.isCameraIntrinsicMatrixDeliverySupported ?? false,
                    "enabled": dc?.isCameraIntrinsicMatrixDeliveryEnabled ?? false,
                    "dataRotation": dc?.videoRotationAngle ?? -1, "movieRotation": mc?.videoRotationAngle ?? -1,
                    "dataStabilization": dc?.activeVideoStabilizationMode.rawValue ?? -99,
                    "movieStabilization": mc?.activeVideoStabilizationMode.rawValue ?? -99,
                    "dataMirrored": dc?.isVideoMirrored ?? false, "movieMirrored": mc?.isVideoMirrored ?? false])
                guard let camera = self.device,
                      let dataConnection = self.intrinsicOutput.connection(with: .video),
                      let movieConnection = self.output.connection(with: .video),
                      movieConnection.activeVideoStabilizationMode == .off,
                      dataConnection.activeVideoStabilizationMode == .off,
                      dataConnection.videoRotationAngle == 0,
                      movieConnection.isVideoMirrored == dataConnection.isVideoMirrored else {
                    throw RecorderError.unavailable("当前配置无法提供与视频一致的真实 K")
                }
                let evidenceURL = directory.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".camera_frames.jsonl")
                if dataConnection.isCameraIntrinsicMatrixDeliveryEnabled {
                    try self.intrinsicRecorder.start(at: evidenceURL, clock: self.session.synchronizationClock, camera: camera)
                } else if self.chosenFPS >= 100 && !dataConnection.isCameraIntrinsicMatrixDeliverySupported {
                    self.intrinsicsUnavailableReason = "该高帧率格式不提供逐帧相机内参 K"
                    self.logger.event("intrinsics_unavailable_record_video", ["fps": self.chosenFPS,
                        "format": self.chosenIndex ?? -1, "reason": self.intrinsicsUnavailableReason ?? ""])
                } else {
                    throw RecorderError.unavailable("当前配置无法提供与视频一致的真实 K")
                }
                self.intrinsicURL = evidenceURL
            } catch {
                try? imu.stop(); self.imuRecorder = nil
                self.releaseExternalMovieAccess()
                self.restoreRAWWhiteBalance()
                self.fail(error.localizedDescription); return
            }
            self.recordingLens = self.device?.localizedName ?? "iPhone camera"
            self.logger.event("record_before_start", ["path": url.path, "state": self.configurationSnapshot()])
            self.recordingStarting = true
            self.startMovieWhenIMUReady(url: url, deadline: ProcessInfo.processInfo.systemUptime + 2)
        }
    }

    /// Older devices can have a ProRes encoder without MovieFileOutput exposing it.
    private var usesProResDataWriter: Bool {
        chosenEncoding.isProRes422 && !output.availableVideoCodecTypes.contains(chosenEncoding.codec)
    }

    private func startRealtimeLUTRecording(url: URL, recipe: LUTBurnRecipe?) {
        do {
            guard let index = chosenIndex, let connection = output.connection(with: .video) else {
                throw RecorderError.unavailable("LUT recording configuration unavailable")
            }
            let format = formatObjects[index]
            var settings = try encodingSettings(for: format, fps: chosenFPS, connection: connection)
            settings[AVVideoWidthKey] = format.width; settings[AVVideoHeightKey] = format.height
            if recipe != nil { settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2] }
            // Without LUT, AVAssetWriter inherits color attachments from capture samples.
            if !chosenEncoding.isProRes422 {
                var compression = settings[AVVideoCompressionPropertiesKey] as? [String: Any] ?? [:]
                compression[AVVideoExpectedSourceFrameRateKey] = chosenFPS
                compression[AVVideoAllowFrameReorderingKey] = false
                if recipe?.highBitDepth == true { compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main10_AutoLevel }
                settings[AVVideoCompressionPropertiesKey] = compression
            }
            let writer = try RealtimeLUTWriter(url: url, recipe: recipe, settings: settings,
                width: Int(format.width), height: Int(format.height), fps: chosenFPS, orientation: recordingOrientation,
                dedicated: UserDefaults.standard.string(forKey: "storageLocation") == "专用视频存储",
                metadata: recordingSlate.metadata, started: { [weak self] pts in
                    guard let self else { return }
                    self.fileOutput(self.output, didStartRecordingTo: url, startPTS: pts, from: [])
                }, finished: { [weak self] error, details in
                    guard let self else { return }
                    self.queue.async {
                        self.previewFanout.setRecordingWriter(nil)
                        if let writer = self.realtimeLUTWriter {
                            self.session.beginConfiguration()
                            self.session.removeOutput(writer.audioOutput)
                            if let settings = self.realtimeLUTVideoSettings { self.intrinsicOutput.videoSettings = settings }
                            self.realtimeLUTVideoSettings = nil
                            self.session.commitConfiguration()
                            self.enableIntrinsicDelivery()
                        }
                        self.realtimeLUTWriter = nil
                        self.logger.event("lut_realtime_finished", details)
                        self.fileOutput(self.output, didFinishRecordingTo: url, from: [], error: error)
                    }
                })
            session.beginConfiguration()
            guard session.canAddOutput(writer.audioOutput) else {
                session.commitConfiguration()
                throw RecorderError.unavailable("LUT audio capture unavailable")
            }
            if recipe?.highBitDepth == true {
                let pixelFormat = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
                                   kCVPixelFormatType_420YpCbCr10BiPlanarFullRange]
                    .first { intrinsicOutput.availableVideoPixelFormatTypes.contains($0) }
                // SDR capture can be 8-bit even when the destination ProRes is
                // 10-bit. HDR/Log capture must never silently fall back to 8-bit.
                let needsTenBitSource = !chosenEncoding.isProRes422 ||
                    [.rec2020HDR, .appleLog, .appleLog2].contains(chosenRecordingColorSpace)
                if let pixelFormat {
                    realtimeLUTVideoSettings = intrinsicOutput.videoSettings
                    intrinsicOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: pixelFormat]
                } else if needsTenBitSource {
                    session.commitConfiguration()
                    throw RecorderError.unavailable("当前配置不支持高位深 LUT 实时录制")
                }
            }
            session.addOutput(writer.audioOutput)
            session.commitConfiguration()
            enableIntrinsicDelivery()
            captureFinishing = true
            recordingTimeSource = recipe == nil ? "ProRes writer; original VideoDataOutput capture PTS preserved" : "Realtime LUT writer; original VideoDataOutput capture PTS preserved"
            realtimeLUTWriter = writer
            logger.event("lut_realtime_started", ["file": url.path, "width": format.width,
                "height": format.height, "fps": chosenFPS, "codec": chosenEncoding.codec.rawValue])
            previewFanout.setRecordingWriter(writer)
        } catch {
            recordingStarting = false
            try? intrinsicRecorder.stop(); try? imuRecorder?.stop(); imuRecorder = nil
            releaseExternalMovieAccess(); restoreRAWWhiteBalance()
            fail(error.localizedDescription)
        }
    }

    private func startMovieWhenIMUReady(url: URL, deadline: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let imu = imuRecorder else { recordingStarting = false; return }
        if let gyro = imu.firstGyroTime, let accel = imu.firstAccelTime,
           uptime - max(gyro, accel) >= 0.07 {
            do { try prepareRAWWhiteBalance() }
            catch {
                recordingStarting = false
                try? intrinsicRecorder.stop()
                try? imu.stop(); imuRecorder = nil
                releaseExternalMovieAccess()
                restoreRAWWhiteBalance()
                fail(error.localizedDescription)
                return
            }
            if recordingLUTBurn != nil || usesProResDataWriter {
                startRealtimeLUTRecording(url: url, recipe: recordingLUTBurn)
                return
            }
            if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                self.output.metadata = self.recordingSlate.metadata
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") {
                    self.captureStartProbe.arm()
                }
                #endif
                self.output.startRecording(to: url, recordingDelegate: self)
            }) {
                recordingStarting = false
                restoreRAWWhiteBalance()
                try? self.intrinsicRecorder.stop()
                try? imu.stop()
                imuRecorder = nil
                let wasExternal = activeExternalMovieURL != nil
                releaseExternalMovieAccess()
                if wasExternal { failStorage("SSD 录制启动失败：\(exception)。请打开设置检查 SSD") }
                else { fail("Start recording: \(exception)") }
            }
        } else if uptime < deadline {
            queue.asyncAfter(deadline: .now() + 0.01) { self.startMovieWhenIMUReady(url: url, deadline: deadline) }
        } else {
            recordingStarting = false
            try? intrinsicRecorder.stop()
            try? imu.stop(); imuRecorder = nil
            releaseExternalMovieAccess()
            restoreRAWWhiteBalance()
            fail("IMU 预录 50 ms 未就绪，录制未开始")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    startPTS: CMTime, from connections: [AVCaptureConnection]) {
        queue.async {
            self.recordingStarting = false
            self.movieFirstFrameHost = try? ClockAligner.hostTime(startPTS, clock: self.session.synchronizationClock)
            self.recordingSlate.advanceTake()
            self.logger.event("record_delegate_start", ["path": fileURL.path, "state": self.configurationSnapshot(),
                "startPTS": startPTS.seconds, "firstHost": self.movieFirstFrameHost ?? -1,
                "outputIsRecording": self.output.isRecording])
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") {
                self.queue.asyncAfter(deadline: .now() + 0.35) {
                    self.logger.event("first_buffer_probe", ["movie": fileURL.lastPathComponent,
                        "timestamps": self.captureStartProbe.snapshot(startPTS: startPTS,
                            clock: self.session.synchronizationClock)])
                }
            }
            #endif
            guard let firstHost = self.movieFirstFrameHost,
                  let raw = self.imuRecorder?.url, let frames = self.intrinsicURL else {
                self.abortRecordingSetup("无法取得视频首帧时间或 IMU/K 文件")
                return
            }
            let recoverySetupStart = ProcessInfo.processInfo.systemUptime
            if self.activeExternalMovieURL != nil && self.activeExternalMovieBookmark == nil {
                do {
                    self.activeExternalMovieBookmark = try fileURL.bookmarkData(options: .minimalBookmark,
                        includingResourceValuesForKeys: nil, relativeTo: nil)
                } catch {
                    self.abortRecordingSetup("无法保存 SSD 素材的恢复授权：\(error.localizedDescription)")
                    return
                }
            }
            let job = PendingIMUJob(movieName: fileURL.lastPathComponent, imuName: raw.lastPathComponent,
                framesName: frames.lastPathComponent, firstHost: firstHost, orientation: self.recordingOrientation,
                camera: Self.hardwareModel(), lens: self.recordingLens,
                mode: UserDefaults.standard.string(forKey: "outputFormat") == "GyroflowProto" ? "GyroflowProto" : "SonyMov",
                retainDebug: UserDefaults.standard.bool(forKey: "debugEnabled") || self.isRAWWriterActive ||
                    ProcessInfo.processInfo.arguments.contains("--imu-sync-4k60-probe") ||
                    ProcessInfo.processInfo.arguments.contains("--first-buffer-probe"),
                externalMovieBookmark: self.activeExternalMovieBookmark,
                expectedVideoCodec: self.chosenCodec?.rawValue,
                expectedFPS: self.chosenFPS,
                intrinsicsUnavailableReason: self.intrinsicsUnavailableReason,
                timingSource: self.recordingTimeSource,
                exposureTimingModel: ExposureTimingModel.recordingModel,
                lutBurn: self.chosenEncoding.isRAW || self.realtimeLUTWriter != nil ? nil : self.recordingLUTBurn)
            do {
                try job.save(in: self.logger.sessionURL.deletingLastPathComponent())
                self.pendingRecordingJob = job
            } catch {
                self.abortRecordingSetup("无法保存 IMU 恢复任务：\(error.localizedDescription)")
                return
            }
            self.logger.event("record_recovery_setup_timing", ["milliseconds":
                (ProcessInfo.processInfo.systemUptime - recoverySetupStart) * 1000])
            self.publish { self.beginFinalizationLease(); self.status = "Recording"; self.recording = true; self.recordingStartedAt = Date(); self.finalizing = false }
            if let codec = self.chosenCodec?.rawValue,
               ProRecordingAccess.freeLimit(codec: codec,
                    purchased: ProRecordingAccess.shared.unlimited, bypass: false) != nil {
                var limit: TimeInterval = 120
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--pro-limit-smoke") { limit = 5 }
                #endif
                let elapsed = CMClockGetTime(CMClockGetHostTimeClock()).seconds - firstHost
                self.queue.asyncAfter(deadline: .now() + max(0, limit - elapsed)) {
                    guard self.currentFile == fileURL, !ProRecordingAccess.shared.unlimited,
                          self.output.isRecording || self.isRAWWriterActive || self.realtimeLUTWriter != nil else { return }
                    self.logger.event("raw_free_limit_reached", ["seconds": limit, "codec": codec])
                    // Use the normal stop/finalization path so audio and IMU survive.
                    self.toggleRecording()
                    self.publish { self.showingProLimit = true }
                }
            }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--imu-sync-4k60-probe") {
                self.runIMUSyncExposureProbe(fileURL: fileURL)
            }
            if ProcessInfo.processInfo.arguments.contains("--ssd-matrix") {
                let seconds = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--ssd-duration=") }
                    .flatMap { Double($0.dropFirst("--ssd-duration=".count)) } ?? 8
                self.queue.asyncAfter(deadline: .now() + seconds) {
                    if self.currentFile == fileURL && (self.output.isRecording || self.isRAWWriterActive || self.realtimeLUTWriter != nil) { self.toggleRecording() }
                }
            }
            if !ProcessInfo.processInfo.arguments.contains("--ssd-matrix") &&
               (ProcessInfo.processInfo.arguments.contains("--hevc-4k60-smoke") ||
               ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") ||
               ProcessInfo.processInfo.arguments.contains("--hevc-1080p120-smoke")) {
                let smokeSeconds: Double = ProcessInfo.processInfo.arguments.first { $0.hasPrefix("--lut-test-seconds=") }
                    .flatMap { Double($0.dropFirst("--lut-test-seconds=".count)) }
                    .map { min(120, max(3, $0)) } ?? (ProcessInfo.processInfo.arguments.contains("--first-buffer-probe") ? 4 : 20)
                self.queue.asyncAfter(deadline: .now() + smokeSeconds) {
                    if self.output.isRecording || self.realtimeLUTWriter != nil { self.toggleRecording() }
                }
            }
            #endif
        }
    }

    private func abortRecordingSetup(_ reason: String) {
        recordingSetupFailure = reason
        logger.event("record_setup_failed", ["reason": reason, "state": configurationSnapshot()])
        publish { self.finalizing = true; self.recording = false; self.recordingStartedAt = nil }
        if let writer = realtimeLUTWriter { writer.abort(reason); return }
        if #available(iOS 27.0, *), let experiment = rawWriterExperiment as? RAWInternalWriterExperiment {
            experiment.stop(); return
        }
        if let exception = RecordingExceptionCatcher.exceptionMessage(for: { self.output.stopRecording() }) {
            logger.event("record_setup_stop_exception", ["reason": exception])
            try? intrinsicRecorder.stop()
            try? imuRecorder?.stop()
            imuRecorder = nil
            recordingSetupFailure = nil
            releaseExternalMovieAccess()
            publish { self.finalizing = false; self.endFinalizationLease() }
            fail("视频录制未完成：\(reason)；停止录制失败：\(exception)")
        }
    }

    private func beginFinalizationLease() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard backgroundLease == .invalid else { return }
        backgroundLease = UIApplication.shared.beginBackgroundTask(withName: "Preserve IMU recording") { [weak self] in
            self?.endFinalizationLease()
        }
    }
    private func endFinalizationLease() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard backgroundLease != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundLease)
        backgroundLease = .invalid
    }
    private var canFinalizeNow: Bool { finalizationAllowed }
    private func resumePendingIMU() {
        guard captureConfigured, !recoveryInProgress, !captureFinishing, !recordingStarting, !output.isRecording, canFinalizeNow else { return }
        let directory = logger.sessionURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.lastPathComponent.hasSuffix(".pending-imu.json") {
            guard canFinalizeNow else { break }
            guard attemptedPendingJobs.insert(file.lastPathComponent).inserted else { continue }
            let signature = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]))?.filter {
                $0.lastPathComponent.hasPrefix(String(file.lastPathComponent.dropLast(".mov.pending-imu.json".count)))
            }.sorted { $0.path < $1.path }.map {
                let value = try? $0.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return "\($0.lastPathComponent):\(value?.fileSize ?? -1):\(value?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
            }.joined(separator: "|") ?? ""
            guard failedPendingSignatures[file.path] != signature else { continue }
            recoveryInProgress = true
            captureFinishing = true
            publish { self.finalizing = true; self.status = "正在补写 IMU…"; self.beginFinalizationLease() }
            let finalizationStart = ProcessInfo.processInfo.systemUptime
            finalizationQueue.async {
                let result = Result { () throws -> PendingIMUJob in
                    let job = try JSONDecoder().decode(PendingIMUJob.self, from: Data(contentsOf: file))
                    try job.complete(in: directory) { stage, seconds in
                        if stage == "LUT" { self.publish { self.status = "LUT \(Int(seconds * 100))%" } }
                        self.logger.event("imu_finalize_stage", ["movie": job.movieName, "stage": stage, "seconds": seconds])
                    }
                    return job
                }
                self.queue.async {
                    self.recoveryInProgress = false
                    self.captureFinishing = false
                    self.finishPendingIMU(result, file: file, signature: signature,
                        directory: directory, finalizationStart: finalizationStart)
                    self.resumePendingIMU()
                }
            }
            return
        }

    }

    private func finishPendingIMU(_ result: Result<PendingIMUJob, Error>, file: URL,
                                  signature: String, directory: URL, finalizationStart: Double) {
        switch result {
        case .success(let job):
                let slateMovie = RecordingStoragePaths.movieDirectory.appendingPathComponent(job.movieName)
                logger.event(job.intrinsicsUnavailableReason == nil ? "imu_pending_completed" : "video_only_completed",
                             ["movie": job.movieName, "reason": job.intrinsicsUnavailableReason ?? ""])
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--slate-smoke") {
                    do {
                        let metadata = AVURLAsset(url: slateMovie).metadata
                        logger.event("slate_smoke_metadata", ["file": slateMovie.lastPathComponent,
                            "values": metadata.compactMap { item -> [String: String]? in
                                guard let key = item.key as? String, let value = item.stringValue else { return nil }
                                return ["key": key, "value": value]
                            }])
                    }
                }
                writeRAWSSDSmokeResult(job, directory: directory)
                #endif
                if let bookmark = job.externalMovieBookmark {
                    var bookmarks = UserDefaults.standard.array(forKey: "externalMediaBookmarks") as? [Data] ?? []
                    if !bookmarks.contains(bookmark) { bookmarks.append(bookmark) }
                    UserDefaults.standard.set(bookmarks, forKey: "externalMediaBookmarks")
                }
                logger.event("imu_finalize_total", ["movie": job.movieName,
                    "seconds": ProcessInfo.processInfo.systemUptime - finalizationStart])
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--writer-repeat"), job.movieName.hasPrefix("UITEST_IMG_writer_") {
                    rawWriterSmokeCompleted += 1
                    logger.event("raw_writer_repeat_complete", ["count": rawWriterSmokeCompleted])
                    if rawWriterSmokeCompleted < 3 { queue.async { self.toggleRecording() } }
                }
                #endif
                publish {
                    self.finalizing = false
                    self.status = job.recordingWarning.map { "已保存 · " + $0 } ?? (
                        job.intrinsicsUnavailableReason != nil ? "视频已保存 · 当前帧率无 K，IMU 未嵌入" : "Saved · IMU embedded")
                    if let warning = job.recordingWarning, warning.contains("丢帧"), self.errorText == nil {
                        self.errorText = "视频与 IMU 已保存，但" + warning
                    }
                    self.endFinalizationLease()
                }
        case .failure(let error):
                logger.event("imu_pending_retry_failed", ["job": file.lastPathComponent, "error": String(describing: error)])
                let deferred = !canFinalizeNow
                let reason = String(describing: error)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--writer-auto-retry"),
                   reason.contains("10 帧"), rawWriterSmokeCompleted == 0,
                   file.lastPathComponent == (rawSmokeMovieName ?? "") + ".pending-imu.json" {
                    rawWriterSmokeCompleted = 1
                    logger.event("raw_writer_auto_retry", ["failedJob": file.lastPathComponent])
                    queue.async { self.clearError(); self.toggleRecording() }
                }
                #endif
                let recordedFailure = (try? JSONDecoder().decode(PendingIMUJob.self, from: Data(contentsOf: file)))?.recordingFailure != nil
                let permanent = PendingIMUJob.isPermanentFailure(reason) || recordedFailure
                if !deferred && permanent {
                    failedPendingSignatures[file.path] = signature
                    do {
                        try PendingIMUJob.retire(file)
                        logger.event("imu_pending_retired", ["job": file.lastPathComponent, "reason": reason])
                    } catch {
                        logger.event("imu_pending_retire_failed", ["job": file.lastPathComponent, "error": String(describing: error)])
                    }
                }
                publish {
                    self.finalizing = false
                    if reason.contains("LUT"), self.errorText == nil { self.errorText = reason }
                    self.status = reason.contains("视频帧时间异常") || reason.contains("视频帧率严重不足")
                        ? "视频帧异常 · 请检查原片" : permanent ? "Camera ready" : "等待返回 App 补写 IMU"
                    self.endFinalizationLease()
                }
                // Recovery is silent: Media exposes missing telemetry as !IMU.

        }
    }

    static func recordingFileSucceeded(_ error: Error?) -> Bool {
        guard let error = error as NSError? else { return true }
        return error.domain == AVFoundationErrorDomain
            && (error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? NSNumber)?.boolValue == true
    }

    static func recordingFailureReason(_ error: Error?) -> String? {
        guard !recordingFileSucceeded(error) else { return nil }
        return error?.localizedDescription ?? "未知错误"
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.recordingStarting = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            self.logger.event("record_delegate_finish", ["path": fileURL.path,
                "fileBytes": attributes?[.size] as? NSNumber ?? 0, "error": error.map { String(describing: $0) } ?? "",
                "state": self.configurationSnapshot()])
            self.restoreRAWWhiteBalance()
            let failureReason = Self.recordingFailureReason(error)
            let externalRecordingFailed = self.activeExternalMovieURL != nil && failureReason != nil
            if let error, failureReason == nil {
                self.logger.event("record_delegate_success_with_warning", ["message": String(describing: error)])
            }
            self.publish { self.recording = false; self.finalizing = true; self.recordingStartedAt = nil }
            self.captureFinishing = true
            let imu = self.imuRecorder
            if self.pendingRecordingJob == nil {
                let reason = self.recordingSetupFailure ?? failureReason ?? "缺少 IMU 恢复任务"
                self.recordingSetupFailure = nil
                try? self.intrinsicRecorder.stop()
                try? imu?.stop()
                self.imuRecorder = nil
                self.captureFinishing = false
                self.releaseExternalMovieAccess()
                self.publish { self.finalizing = false; self.endFinalizationLease() }
                self.fail("视频录制未完成：\(reason)。原始文件已保留")
                return
            }
            // Keep collecting the 50 ms tail before closing durable raw data.
            self.queue.asyncAfter(deadline: .now() + 0.12) {
                self.imuRecorder = nil
                do {
                    let framesStop = Result { if self.intrinsicsUnavailableReason == nil { try self.intrinsicRecorder.stop() } }
                    var cadence = self.intrinsicRecorder.diagnostics()
                    cadence["file"] = fileURL.lastPathComponent
                    self.logger.event("intrinsics_capture_health", cadence)
                    let imuStop = Result { try imu?.stop() }
                    guard var job = self.pendingRecordingJob else { throw RecorderError.unavailable("缺少 IMU 恢复任务") }
                    job.ready = true
                    job.recordingFailure = failureReason
                    job.recordingWarning = failureReason ?? self.recordingCadenceWarning
                    try job.save(in: self.logger.sessionURL.deletingLastPathComponent())
                    try framesStop.get(); try imuStop.get()
                    self.pendingRecordingJob = nil
                    self.captureFinishing = false
                    self.publish { self.finalizing = false; self.status = "等待返回 App 补写 IMU"; self.endFinalizationLease() }
                    self.resumePendingIMU()
                    self.releaseExternalMovieAccess()
                    if externalRecordingFailed {
                        self.failStorage("SSD 录制中断：\(failureReason ?? "存储不可用")。原始文件已保留",
                                         retryOnReconnect: true)
                    } else if let failureReason {
                        self.fail("录制已停止：\(failureReason)。原始文件已保留")
                    }
                } catch {
                    self.captureFinishing = false
                    self.releaseExternalMovieAccess()
                    self.logger.event("imu_preserve_failed", ["error": String(describing: error)])
                    self.publish {
                        self.finalizing = false
                        self.endFinalizationLease()
                        self.status = "等待返回 App 补写 IMU"
                    }
                }
            }
        }
    }

    private func installFocusObservers(_ camera: AVCaptureDevice) {
        observations = [
            camera.observe(\.focusMode, options: [.old, .new]) { [weak self] _, change in
                self?.logger.event("focus_mode_kvo", ["old": change.oldValue.map { self?.focusName($0) ?? "?" } ?? "?",
                                                      "new": change.newValue.map { self?.focusName($0) ?? "?" } ?? "?"])
                if let mode = change.newValue { self?.publish { self?.actualFocusMode = self?.focusName(mode) ?? "?" } }
            },
            camera.observe(\.isAdjustingFocus, options: [.old, .new]) { [weak self] _, change in
                self?.logger.event(change.newValue == true ? "af_adjusting_start" : "af_adjusting_end",
                                   ["old": change.oldValue ?? false, "new": change.newValue ?? false])
                self?.publish { self?.adjusting = change.newValue ?? false }
                if change.oldValue == true && change.newValue == false {
                    self?.queue.async { [weak self, weak camera] in
                        guard let self, let camera, self.device === camera,
                              self.chosenFocus == .locked,
                              (camera.focusMode == .autoFocus || camera.focusMode == .locked),
                              !camera.isAdjustingFocus else { return }
                        // Save the completed focus, not the position before the scan.
                        self.savedControls.focusPosition = camera.lensPosition
                        self.savedControls.save()
                        self.logger.event("point_focus_locked", ["position": camera.lensPosition,
                            "point": ["x": camera.focusPointOfInterest.x, "y": camera.focusPointOfInterest.y]])
                    }
                }
            },
            camera.observe(\.lensPosition, options: [.old, .new]) { [weak self] _, change in
                self?.logger.event("lens_position_kvo", ["old": change.oldValue ?? 0, "new": change.newValue ?? 0])
                self?.publish { self?.lensPosition = change.newValue ?? 0 }
            }
        ]
    }

    private func startSampling(_ camera: AVCaptureDevice) {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        timer.setEventHandler { [weak self, weak camera] in
            guard let self, let camera else { return }
            self.telemetryReadoutTick += 1
            if self.telemetryReadoutTick % 20 == 0 {
                self.replenishDeletedVideoStorageIfPossible()
                self.refreshStorageBudget()
            }
            if self.telemetryReadoutTick % 5 == 0 {
                var whiteBalanceError: NSString?
                let temperature = RecordingExceptionCatcher.whiteBalanceTemperature(
                    for: camera, error: &whiteBalanceError)?.floatValue
                if let whiteBalanceError, self.telemetryReadoutTick % 50 == 0 {
                    self.logger.event("white_balance_readout_skipped", ["reason": whiteBalanceError])
                }
                let iso = camera.iso
                let exposureSeconds = CMTimeGetSeconds(camera.exposureDuration)
                let exposureAuto = camera.exposureMode == .continuousAutoExposure
                let whiteBalanceAuto = camera.whiteBalanceMode == .continuousAutoWhiteBalance
                let bias = Double(camera.exposureTargetBias)
                let biasRange = max(-6, Double(camera.minExposureTargetBias))...min(6, Double(camera.maxExposureTargetBias))
                self.publish {
                    self.iso = iso
                    self.exposureBias = bias; self.exposureBiasRange = biasRange
                    self.exposureSeconds = exposureSeconds
                    if let temperature { self.whiteBalanceKelvin = temperature }
                    self.exposureAuto = exposureAuto
                    self.whiteBalanceAuto = whiteBalanceAuto
                }
            }
            if (self.output.isRecording || self.isRAWWriterActive || self.realtimeLUTWriter != nil) && self.telemetryReadoutTick % 10 == 0 {
                self.logger.event("recording_health", [
                    "thermalState": ProcessInfo.processInfo.thermalState.rawValue,
                    "pressureLevel": camera.systemPressureState.level.rawValue,
                    "pressureFactors": camera.systemPressureState.factors.rawValue,
                    "minFrameSeconds": camera.activeVideoMinFrameDuration.seconds,
                    "maxFrameSeconds": camera.activeVideoMaxFrameDuration.seconds,
                    "exposureSeconds": camera.exposureDuration.seconds,
                    "whiteBalanceMode": camera.whiteBalanceMode.rawValue,
                    "whiteBalanceChoice": self.chosenWhiteBalance.rawValue,
                    "whiteBalanceGains": [camera.deviceWhiteBalanceGains.redGain, camera.deviceWhiteBalanceGains.greenGain, camera.deviceWhiteBalanceGains.blueGain]
                ])
            }
            self.logger.event("focus_sample", ["focusMode": self.focusName(camera.focusMode),
                                                "adjusting": camera.isAdjustingFocus, "lensPosition": camera.lensPosition,
                                                "recording": self.output.isRecording])
        }
        timer.resume(); sampleTimer = timer
    }

    #if DEBUG
    private func startResponsivenessProbe() {
        let monitor = DispatchQueue(label: "GyroCine.responsiveness", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: monitor)
        var ticks = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            ticks += 1
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                self.logger.event("main_queue_latency", ["ms": (ProcessInfo.processInfo.systemUptime - sent) * 1000])
            }
            self.queue.async {
                self.logger.event("camera_queue_latency", ["ms": (ProcessInfo.processInfo.systemUptime - sent) * 1000])
            }
            if ticks >= 80 { timer.cancel() }
        }
        responsivenessTimer = timer; timer.resume()
    }
    #endif

    private func observeSessionEvents() {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification, UIApplication.willResignActiveNotification, UIApplication.didBecomeActiveNotification,
                     UIApplication.protectedDataDidBecomeAvailableNotification, UIApplication.protectedDataWillBecomeUnavailableNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.didActivateNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let allowed = UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
                if name == UIApplication.didEnterBackgroundNotification || name == UIScene.didEnterBackgroundNotification {
                    DispatchQueue.main.async { self.beginFinalizationLease() }
                }
                self.queue.async {
                    self.finalizationAllowed = allowed
                    if !allowed { self.ssdSpeedCancellation?.cancel() }
                    if name == UIApplication.willEnterForegroundNotification {
                        self.attemptedPendingJobs.removeAll()
                        self.storageReplenishPending = true
                        self.storageReplenishFromDeletion = false
                        self.storageReplenishRetries = 0
                        self.storageReplenishNotBefore = 0
                    }
                    if name == UIApplication.didBecomeActiveNotification || name == UIScene.didActivateNotification || name == UIApplication.protectedDataDidBecomeAvailableNotification {
                        self.resumePendingIMU()
                    }
                    if name == UIApplication.didEnterBackgroundNotification, !self.output.isRecording, !self.captureFinishing {
                        self.publish { self.endFinalizationLease() }
                    }
                    self.logger.event("lifecycle", ["name": name.rawValue,
                                                    "error": note.userInfo?[AVCaptureSessionErrorKey].map { String(describing: $0) } ?? ""])
                    if (name == UIApplication.willResignActiveNotification || name == UIScene.willDeactivateNotification || name == UIApplication.didEnterBackgroundNotification || name == UIScene.didEnterBackgroundNotification), self.output.isRecording { self.output.stopRecording() }
                    if let writer = self.realtimeLUTWriter,
                       [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
                        UIApplication.didEnterBackgroundNotification, AVCaptureSession.wasInterruptedNotification,
                        AVCaptureSession.runtimeErrorNotification].contains(name) {
                        self.publish { self.finalizing = true }; writer.stop()
                    }
                    if #available(iOS 27.0, *), let experiment = self.rawWriterExperiment as? RAWInternalWriterExperiment,
                       [UIApplication.willResignActiveNotification, UIScene.willDeactivateNotification,
                        UIApplication.didEnterBackgroundNotification, AVCaptureSession.wasInterruptedNotification,
                        AVCaptureSession.runtimeErrorNotification].contains(name) {
                        self.publish { self.finalizing = true }
                        experiment.stop()
                    }
                    if name == UIApplication.willEnterForegroundNotification || name == AVCaptureSession.interruptionEndedNotification {
                        if self.captureConfigured && !self.session.isRunning { self.session.startRunning() }
                        let running = self.session.isRunning
                        self.publish { self.status = running ? "Camera ready" : "Camera interrupted"; self.cameraReady = running }
                    }
                    if name == AVCaptureSession.wasInterruptedNotification { self.publish { self.status = "Camera interrupted"; self.cameraReady = false } }
                    if name == AVCaptureSession.runtimeErrorNotification { self.fail("Capture session runtime error") }
                }
            })
        }
    }

    func export(_ capability: Bool) {
        logger.flush { self.exportURL = capability ? self.logger.capabilityURL : self.logger.sessionURL }
    }

    func clearError() { publish { self.errorText = nil; self.storageSetupRequired = false } }
}

private enum CameraError: LocalizedError {
    case unsupportedFocus(String)
    case unavailableCodec(String, Int)
    var errorDescription: String? {
        switch self {
        case .unsupportedFocus(let name): "Unsupported focus: \(name)"
        case .unavailableCodec(let codec, let index): "Codec \(codec) unavailable on format [\(index)] at selected FPS"
        }
    }
}
