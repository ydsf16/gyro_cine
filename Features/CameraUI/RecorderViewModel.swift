import Foundation
import SwiftUI
import AVFoundation

enum SSDStorageError: LocalizedError {
    case notConnected, permissionDenied, insufficientSpace, fileAccess(String), folderAccess(String)

    var title: String {
        switch self {
        case .notConnected: "未检测到 SSD"
        case .permissionDenied: "SSD 访问权限未开启"
        case .insufficientSpace: "SSD 空间不足"
        case .fileAccess: "无法访问 SSD"
        case .folderAccess: "无法创建录制文件夹"
        }
    }
    var errorDescription: String? {
        switch self {
        case .notConnected: "请连接外置 SSD 后重试。"
        case .permissionDenied: "请在 iPhone 设置中允许此 App 访问外置存储。"
        case .insufficientSpace: "SSD 至少需要 2 GB 可用空间。"
        case .fileAccess(let detail): "SSD 已连接且已授权，但无法取得写入位置：\(detail)"
        case .folderAccess(let detail): "SSD 已连接且已授权，但无法写入所选位置的 DCIM 文件夹：\(detail)"
        }
    }
}

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var message: String?
    @Published var audioEnabled = true
    @Published var codecMode: RecordingCodec = .hevc
    @Published private(set) var availableWriterCodecTags = Set<String>()
    @Published var controls = CameraControls()
    @Published var colorSpace: RecordingColorSpace = .rec709
    @Published private(set) var storageLocation: RecordingStorage = .files
    @Published private(set) var selectedSSDFolderName: String?
    private var selectedSSDFolder: URL?
    private var ssdAccessURL: URL?
    @Published var outputMode: RecordingOutputMode = RecordingOutputMode(rawValue: UserDefaults.standard.string(forKey: "recordingOutputMode") ?? "") ?? .sonyMOV {
        didSet { UserDefaults.standard.set(outputMode.rawValue, forKey: "recordingOutputMode") }
    }
    private var recordingOutputMode: RecordingOutputMode = .sonyMOV
    var selectedCodec: RecordingCodec { codecMode }
    func canSelectCodec(_ codec: RecordingCodec) -> Bool {
        if codec.isRAW { return supportsRAW }
        if codec.isProRes { return codec.avCodec.map { availableWriterCodecTags.contains($0.rawValue) } ?? false }
        if !selectedCodec.isRAW && !availableWriterCodecTags.isEmpty {
            return codec.avCodec.map { availableWriterCodecTags.contains($0.rawValue) } ?? false
        }
        guard let device = cameraDevice else { return codec == .hevc || codec == .h264 }
        return !CameraCapabilityScanner.modes(device: device, codec: codec, color: .rec709).isEmpty
    }
    var codecOptions: [RecordingCodec] {
        RecordingCodec.selectableCases.filter { canSelectCodec($0) || $0 == selectedCodec }
    }
    var videoLabel: String { "\(selectedCodec.label) · \(selectedMode?.label ?? "不可用")" }
    var supportsRAW: Bool {
        guard #available(iOS 26.0, *) else { return false }
        guard let device = selectedLens.flatMap({ CameraCapabilityScanner.device(id: $0.id) }) else { return false }
        return !CameraCapabilityScanner.modes(device: device, codec: .proResRAW).isEmpty
    }
    @Published var shutter: ShutterSetting = .oneFiveHundredth
    @Published var debugFilesEnabled = UserDefaults.standard.bool(forKey: "debugFilesEnabled") {
        didSet { UserDefaults.standard.set(debugFilesEnabled, forKey: "debugFilesEnabled") }
    }
    @Published var actualISO: Float = 100
    @Published var actualExposure: Double = 1.0 / 60
    @Published var actualTemperature: Float = 5600
    @Published var actualTint: Float = 0
    @Published var exposureReadout = "等待相机读数"
    @Published var recordings: [URL] = []
    @Published var imuRateLabel = "pending"
    @Published var elapsedSeconds = 0
    @Published private(set) var lenses: [CameraLens] = []
    @Published private(set) var selectedLens: CameraLens?
    var canSelectLens: Bool { state == .ready || state == .completed || state == .failed }
    let coordinator = CaptureCoordinator()
    private let motion = MotionRecorder()
    private var currentFolder: URL?
    private var recordingOrientation: RecordingOrientation = .landscapeRight
    private var recordingColorSpace: RecordingColorSpace = .rec709
    private var recordingDebugFiles = false
    private var recordingStorageLocation: RecordingStorage = .files
    private var started = false
    private var recordingTimer: Timer?
    private var primingTask: Task<Void, Never>?

    var previewSession: AVCaptureSession { coordinator.session }
    var modes: [CameraMode] {
        guard let device = selectedLens.flatMap({ CameraCapabilityScanner.device(id: $0.id) }) ?? CameraCapabilityScanner.mainCamera() else { return [] }
        return CameraCapabilityScanner.modes(device: device, codec: selectedCodec, color: selectedCodec.isRAW ? nil : colorSpace)
    }
    @Published private(set) var selectedMode: CameraMode?
    var resolutionOptions: [CameraMode] {
        var seen = Set<String>()
        return modes.filter { seen.insert("\($0.width)x\($0.height)").inserted }
    }
    var resolutionKey: String { selectedMode.map { "\($0.width)x\($0.height)" } ?? "" }
    var frameRateOptions: [Int] {
        modes.filter { "\($0.width)x\($0.height)" == resolutionKey }.map(\.fps)
    }
    func selectResolution(_ key: String) {
        guard canSelectLens else { return }
        let candidates = modes.filter { "\($0.width)x\($0.height)" == key }
        selectedMode = candidates.first { $0.fps == selectedMode?.fps } ?? candidates.first { $0.fps == 30 } ?? candidates.first
        reconfigure()
    }
    func selectFrameRate(_ fps: Int) {
        guard canSelectLens, let mode = modes.first(where: { "\($0.width)x\($0.height)" == resolutionKey && $0.fps == fps }) else { return }
        selectedMode = mode
        reconfigure()
    }
    var supportedShutters: [ShutterSetting] {
        guard let device = selectedLens.flatMap({ CameraCapabilityScanner.device(id: $0.id) }),
              let mode = selectedMode else { return [.auto] }
        return ShutterSetting.allCases.filter { $0.isSupported(by: device, mode: mode) }
    }
    var cameraDevice: AVCaptureDevice? { selectedLens.flatMap { CameraCapabilityScanner.device(id: $0.id) } }
    var isoRange: ClosedRange<Double> {
        guard let d = cameraDevice, let m = selectedMode else { return 25...3200 }
        let f = d.formats[m.formatIndex]
        return Double(f.minISO)...Double(f.maxISO)
    }
    var colorOptions: [RecordingColorSpace] {
        [.rec709]
    }
    var canAdjustSensorControls: Bool { canSelectLens || state == .recording }
    var exposureRange: ClosedRange<Double> {
        guard let device = cameraDevice, let mode = selectedMode else { return (1.0 / 2000)...(1.0 / 30) }
        let format = device.formats[mode.formatIndex]
        let lower = max(0.000001, format.minExposureDuration.seconds)
        return lower...max(lower, min(format.maxExposureDuration.seconds, 1.0 / Double(mode.fps)))
    }
    func applyControls(_ update: (inout CameraControls) -> Void) {
        guard canAdjustSensorControls else { return }
        var next = controls
        update(&next)
        next.exposureSeconds = min(exposureRange.upperBound, max(exposureRange.lowerBound, next.exposureSeconds))
        next.iso = Float(min(isoRange.upperBound, max(isoRange.lowerBound, Double(next.iso))))
        controls = next
        coordinator.updateControls(next, shutter: shutter) { [weak self] error in
            Task { @MainActor in if let error { self?.message = error } }
        }
    }
    func setAutomaticExposure(_ automatic: Bool) {
        applyControls { next in
            if !automatic && !next.manualExposure {
                next.exposureSeconds = actualExposure
                next.iso = actualISO
            }
            next.manualExposure = !automatic
        }
    }
    func setExposureLimit(_ value: ShutterSetting) {
        guard canAdjustSensorControls else { return }
        shutter = value
        applyControls { $0.manualExposure = false }
    }
    func setAutomaticWhiteBalance(_ automatic: Bool) {
        applyControls { next in
            if !automatic && next.automaticWhiteBalance {
                next.temperature = actualTemperature
                next.tint = actualTint
            }
            next.automaticWhiteBalance = automatic
        }
    }
    var capabilityLabel: String { modes.isEmpty ? "当前镜头不支持所选编码" : "\(videoLabel) · 编码器按实际会话验证" }
    var canToggle: Bool { state == .ready || state == .recording || state == .completed }
    var thermalLabel: String {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: "thermal nominal"
        case .fair: "thermal fair"
        case .serious: "thermal serious"
        case .critical: "thermal critical"
        @unknown default: "thermal unknown"
        }
    }
    var freeSpaceLabel: String {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let bytes = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    init() {
        restoreStorageLocation()
        coordinator.onAvailableWriterCodecs = { [weak self] codecs in
            Task { @MainActor in self?.availableWriterCodecTags = Set(codecs.map(\.rawValue)) }
        }
        coordinator.onState = { [weak self] state, message in
            Task { @MainActor in
                self?.state = state
                self?.message = message
                if state == .recording { self?.startStatusTimer() }
                else {
                    self?.recordingTimer?.invalidate(); self?.recordingTimer = nil
                    if state == .completed || state == .ready || state == .failed { self?.elapsedSeconds = 0 }
                }
                DiagnosticsCollector.record("state=\(state.rawValue) message=\(message ?? "none")", folder: self?.currentFolder)
                if state == .failed {
                    self?.motion.stop()
                    self?.recordFailure(message ?? "Capture failed")
                    self?.refreshRecordings()
                }
            }
        }
        coordinator.onCaptureFinished = { [weak self] in
            Task { @MainActor in self?.motion.stop() }
        }
        coordinator.onCompleted = { [weak self] url, clock, frames, error in
            Task { @MainActor in await self?.finish(url: url, clock: clock, frames: frames, error: error) }
        }
        coordinator.onWhiteBalanceReading = { [weak self] temperature, tint in
            Task { @MainActor in
                if temperature.isFinite && tint.isFinite { self?.actualTemperature = temperature; self?.actualTint = tint }
            }
        }
        coordinator.onExposureReading = { [weak self] duration, iso in
            Task { @MainActor in
                guard duration.isFinite, duration > 0, iso.isFinite else { return }
                self?.actualISO = iso
                self?.actualExposure = duration
                self?.exposureReadout = String(format: "实际约 1/%.1f 秒 · ISO %.0f", 1 / duration, iso)
            }
        }
    }

    func prepare() {
        guard !started else { return }
        started = true
        motion.startOrientationMonitoring()
        try? FileManager.default.createDirectory(at: RecordingStorage.filesRoot, withIntermediateDirectories: true)
        if let entries = try? FileManager.default.contentsOfDirectory(at: RecordingStorage.filesRoot, includingPropertiesForKeys: nil) {
            for url in entries where url.lastPathComponent.hasPrefix("capture_capabilities_") && url.pathExtension == "json" {
                try? FileManager.default.removeItem(at: url)
            }
        }
        refreshRecordings()
        lenses = CameraCapabilityScanner.lenses()
        selectedLens = lenses.first { $0.deviceType == AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue && $0.supports4K30 }
            ?? lenses.first { $0.supports4K30 }
        reconfigure()
    }

    @Published var frontCamera = false
    @Published var externalStorageStatus = "正在检测外接存储…"

    func useFilesStorage() {
        storageLocation = .files
        ssdAccessURL?.stopAccessingSecurityScopedResource()
        ssdAccessURL = nil
        selectedSSDFolder = nil
        selectedSSDFolderName = nil
        UserDefaults.standard.set(RecordingStorage.files.rawValue, forKey: "recordingStorageLocation")
        refreshRecordings()
    }

    /// Returns false when the user must grant one-time folder access in Files.
    func useSSDStorage() async throws -> Bool {
        guard let disk = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.first(where: { $0.isConnected }) else {
            throw SSDStorageError.notConnected
        }
        if AVExternalStorageDevice.authorizationStatus == .notDetermined {
            let allowed = await withCheckedContinuation { continuation in
                AVExternalStorageDevice.requestAccess { continuation.resume(returning: $0) }
            }
            guard allowed else { throw SSDStorageError.permissionDenied }
        }
        guard AVExternalStorageDevice.authorizationStatus == .authorized else { throw SSDStorageError.permissionDenied }
        guard disk.freeSize >= 2_000_000_000 else { throw SSDStorageError.insufficientSpace }
        if selectedSSDFolder == nil { loadSSDBookmark() }
        guard let folder = selectedSSDFolder, ssdAccessURL != nil else { return false }
        do {
            try verifySSDDirectory(folder)
            selectedSSDFolderName = disk.displayName
            storageLocation = .ssd
            UserDefaults.standard.set(RecordingStorage.ssd.rawValue, forKey: "recordingStorageLocation")
            refreshRecordings()
            return true
        } catch {
            ssdAccessURL?.stopAccessingSecurityScopedResource()
            ssdAccessURL = nil
            selectedSSDFolder = nil
            return false // Expired folder grant: request a new folder from Files.
        }
    }

    func chooseSSDFolder(_ url: URL) throws {
        guard AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.contains(where: { $0.isConnected }) == true else {
            throw SSDStorageError.notConnected
        }
        guard url.startAccessingSecurityScopedResource() else {
            throw SSDStorageError.folderAccess("系统没有授予所选文件夹访问权限")
        }
        do {
            try verifySSDDirectory(url)
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            ssdAccessURL?.stopAccessingSecurityScopedResource()
            ssdAccessURL = url
            selectedSSDFolder = url
            selectedSSDFolderName = url.lastPathComponent
            storageLocation = .ssd
            UserDefaults.standard.set(bookmark, forKey: "recordingSSDFolderBookmark")
            UserDefaults.standard.set(RecordingStorage.ssd.rawValue, forKey: "recordingStorageLocation")
            refreshRecordings()
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw SSDStorageError.folderAccess(error.localizedDescription)
        }
    }

    private func verifySSDDirectory(_ parent: URL) throws {
        let root = try RecordingStorage.createSSDRoot(in: parent)
        let probe = root.appendingPathComponent(".write-test")
        try Data().write(to: probe, options: .atomic)
        try FileManager.default.removeItem(at: probe)
    }

    private func loadSSDBookmark() {
        guard let bookmark = UserDefaults.standard.data(forKey: "recordingSSDFolderBookmark") else { return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale),
              !stale, url.startAccessingSecurityScopedResource() else { return }
        ssdAccessURL = url
        selectedSSDFolder = url
        selectedSSDFolderName = url.lastPathComponent
    }

    private func restoreStorageLocation() {
        guard UserDefaults.standard.string(forKey: "recordingStorageLocation") == RecordingStorage.ssd.rawValue else { return }
        loadSSDBookmark()
        if selectedSSDFolder != nil { storageLocation = .ssd }
    }

    private func selectedRecordingRoot() throws -> URL {
        if storageLocation == .files { return RecordingStorage.filesRoot }
        guard let parent = selectedSSDFolder, ssdAccessURL != nil,
              AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.contains(where: { $0.isConnected }) == true else {
            throw RecorderError.unavailable("SSD 未连接；请在设置中重新启用 SSD 录制位置")
        }
        let root = try RecordingStorage.createSSDRoot(in: parent)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecorderError.unavailable("SSD 上的 DCIM 文件夹不可写；请在设置中重新启用 SSD")
        }
        do { try verifySSDDirectory(parent) }
        catch { throw SSDStorageError.folderAccess(error.localizedDescription) }
        return root
    }

    func refreshExternalStorage() {
        let disks = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter { $0.isConnected } ?? []
        if disks.isEmpty { externalStorageStatus = "未检测到 SSD；请连接后重试" }
        else if AVExternalStorageDevice.authorizationStatus != .authorized { externalStorageStatus = "SSD 已连接，录制时请求访问权限" }
        else if !disks.contains(where: { $0.freeSize >= 2_000_000_000 }) { externalStorageStatus = "SSD 可用空间不足 2 GB" }
        else { externalStorageStatus = AVExternalStorageDevice.authorizationStatus == .authorized ? "SSD 已连接，可录制 RAW" : "SSD 已连接，录制时请求访问权限" }
    }

    func switchCamera() {
        guard canSelectLens else { return }
        let candidates = CameraCapabilityScanner.lenses(position: frontCamera ? .back : .front)
        guard let lens = candidates.first(where: { $0.displayMultiplier == 1 }) ?? candidates.first else { return }
        frontCamera.toggle()
        lenses = candidates
        selectedLens = lens
        if selectedCodec.isRAW && !supportsRAW { codecMode = .hevc }
        reconfigure()
    }

    func selectLens(_ lens: CameraLens) {
        guard canSelectLens, lenses.contains(lens), lens.id != selectedLens?.id else { return }
        selectedLens = lens
        if !supportedShutters.contains(shutter) { shutter = supportedShutters.contains(.oneFiveHundredth) ? .oneFiveHundredth : (supportedShutters.first ?? .auto) }
        reconfigure()
    }

    func reconfigure() {
        guard state != .recording, state != .finalizing, state != .configuring else { return }
        if !colorOptions.contains(colorSpace) { colorSpace = .rec709 }
        let available = modes
        selectedMode = CameraMode.preferred(in: available, previous: selectedMode)
        if !supportedShutters.contains(shutter) { shutter = supportedShutters.contains(.oneFiveHundredth) ? .oneFiveHundredth : (supportedShutters.first ?? .auto) }
        state = .configuring
        coordinator.configure(audio: audioEnabled, cameraID: selectedLens?.id, shutter: shutter, codec: selectedCodec, requestedMode: selectedMode, controls: controls, color: colorSpace)
    }

    func start() {
        guard state == .ready || state == .completed else { return }
        if selectedCodec.isRAW {
            guard storageLocation == .ssd else {
                state = .failed
                message = "ProRes RAW / RAW HQ 录制前，请在设置中将录制位置改为 SSD。"
                return
            }
            do { _ = try selectedRecordingRoot() }
            catch {
                state = .failed
                message = error.localizedDescription
                return
            }
            guard AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.contains(where: { $0.isConnected }) == true else {
                state = .failed
                message = "ProRes RAW / RAW HQ 需要外接 SSD；请连接后重试。"
                return
            }
            if AVExternalStorageDevice.authorizationStatus != .authorized {
                state = .configuring
                AVExternalStorageDevice.requestAccess { [weak self] allowed in
                    Task { @MainActor in
                        guard let self else { return }
                        self.state = allowed ? .ready : .failed
                        if allowed { self.start() } else { self.message = "请允许访问外接存储后重试" }
                    }
                }
                return
            }
        }
        guard let physicalOrientation = motion.recordingDirection else {
            message = "正在读取手机方向，请将手机稍微立起后重试"
            return
        }
        state = .configuring // Disable lens changes immediately, including before the first video sample.
        recordingOrientation = physicalOrientation
        recordingColorSpace = colorSpace
        recordingDebugFiles = debugFilesEnabled

        do {
            guard motion.isAvailable else { throw RecorderError.unavailable("Raw motion sensors unavailable") }
            let destinationRoot = try selectedRecordingRoot()
            let capacity = try? destinationRoot.resourceValues(forKeys: [
                .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey
            ])
            let disks = AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.filter { $0.isConnected } ?? []
            // A single connected disk is unambiguous. With multiple disks use the selected URL's volume.
            let externalBytes = storageLocation == .ssd && disks.count == 1 ? Int64(disks[0].freeSize) : nil
            guard let freeBytes = RecordingStorage.availableBytes(location: storageLocation,
                external: externalBytes, ordinary: capacity?.volumeAvailableCapacity.map(Int64.init),
                important: capacity?.volumeAvailableCapacityForImportantUsage) else {
                throw RecorderError.unavailable("无法读取录制位置的剩余空间，请重新连接并授权 SSD 后重试")
            }
            guard freeBytes >= 2_000_000_000 else {
                let available = ByteCountFormatter.string(fromByteCount: freeBytes, countStyle: .file)
                throw RecorderError.unavailable("\(storageLocation.label)可用空间不足：读取到 \(available)，录制至少需要 2 GB")
            }
            let date = DateFormatter()
            date.dateFormat = "yyyyMMdd_HHmmss"
            let folder = destinationRoot.appendingPathComponent("GyroCine_\(date.string(from: Date()))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            currentFolder = folder
            recordingStorageLocation = storageLocation
            recordingOutputMode = outputMode
            DiagnosticsCollector.record("storage capacity location=\(storageLocation.rawValue) selected=\(freeBytes) external=\(String(describing: externalBytes)) ordinary=\(String(describing: capacity?.volumeAvailableCapacity)) important=\(String(describing: capacity?.volumeAvailableCapacityForImportantUsage))", folder: folder)
            DiagnosticsCollector.record("start requested codec=\(selectedCodec.label) video=\(selectedMode?.label ?? "unknown") audio=\(audioEnabled) shutter=\(shutter.label) lens=\(selectedLens?.name ?? "unknown") multiplier=\(selectedLens?.label ?? "unknown") cameraID=\(selectedLens?.id ?? "unknown")", folder: folder)
            try motion.start(at: folder.appendingPathComponent("imu_raw.jsonl"))
            DiagnosticsCollector.record("IMU pre-roll started; waiting for 100ms of gyro samples", folder: folder)
            primingTask = Task { @MainActor [weak self] in
                guard let self else { return }
                for _ in 0..<200 {
                    if Task.isCancelled { return }
                    if self.motion.gyroSpanSeconds >= 0.100 { break }
                    try? await Task.sleep(for: .milliseconds(10))
                }
                guard !Task.isCancelled, self.currentFolder == folder, self.state == .configuring else { return }
                guard self.motion.gyroSpanSeconds >= 0.100, self.motion.error == nil else {
                    self.motion.stop()
                    self.state = .failed
                    self.message = self.motion.error ?? "Gyroscope did not supply 100ms of pre-roll samples"
                    self.recordFailure(self.message ?? "IMU pre-roll failed")
                    self.refreshRecordings()
                    return
                }
                DiagnosticsCollector.record("IMU pre-roll ready spanMs=\(self.motion.gyroSpanSeconds * 1000)", folder: folder)
                self.coordinator.start(at: folder.recordingFile("mov"), orientation: self.recordingOrientation,
                    externalDestination: self.recordingStorageLocation == .ssd)
                self.primingTask = nil
            }
        } catch {
            state = .failed
            message = error.localizedDescription
        }
    }

    func stop() {
        if state == .configuring, primingTask != nil {
            primingTask?.cancel()
            primingTask = nil
            motion.stop()
            state = .ready
            message = "Recording cancelled during IMU pre-roll"
            currentFolder = nil
            return
        }
        coordinator.stop()
    }

    private func startStatusTimer() {
        elapsedSeconds = 0
        recordingTimer?.invalidate()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.elapsedSeconds += 1
                self.imuRateLabel = "\(self.motion.count) events"
            }
        }
    }

    func retry() {
        currentFolder = nil
        reconfigure()
    }

    private func recordFailure(_ reason: String) {
        guard let folder = currentFolder else { return }
        var diagnostics = RecordingDiagnostics(deviceModel: RecorderIdentity.cameraModel,
            systemVersion: UIDevice.current.systemVersion, configuredCodec: selectedCodec.label,
            audioEnabled: audioEnabled, requestedVideo: selectedMode?.label ?? "unknown",
            submittedFrameCount: 0, motionEventCount: motion.count,
            clock: nil, captureError: reason, status: "failed")
        diagnostics.outputMode = recordingOutputMode
        diagnostics.recordingRotationDegrees = recordingOrientation.degrees
        diagnostics.recordedColorSpace = selectedCodec.isRAW ? "Sensor RAW" : recordingColorSpace.label
        diagnostics.requestedFrameRate = selectedMode?.fps
        diagnostics.selectedLens = selectedLens
        diagnostics.requestedShutter = shutter.label
        diagnostics.exposureControlMode = controls.manualExposure ? "customExposure" : "continuousAutoExposureWithDurationLimit"
        diagnostics.requestedMaximumExposureDurationSeconds = shutter.durationSeconds
        try? JSONEncoder.pretty.encode(diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
        DiagnosticsCollector.record("failed reason=\(reason)", folder: folder)
    }

    private func finish(url: URL, clock: ClockEvidence?, frames: Int, error: String?) async {
        primingTask?.cancel()
        primingTask = nil
        motion.stop()
        guard let folder = currentFolder else { return }
        var diagnostics = RecordingDiagnostics(
            deviceModel: RecorderIdentity.cameraModel,
            systemVersion: UIDevice.current.systemVersion,
            configuredCodec: selectedCodec.label, audioEnabled: audioEnabled, requestedVideo: selectedMode?.label ?? "unknown",
            submittedFrameCount: frames, motionEventCount: motion.count,
            clock: clock, captureError: error ?? motion.error,
            status: error == nil && motion.error == nil ? "finalizing" : "failed")
        diagnostics.outputMode = recordingOutputMode
        diagnostics.recordingRotationDegrees = recordingOrientation.degrees
        diagnostics.recordedColorSpace = selectedCodec.isRAW ? "Sensor RAW" : recordingColorSpace.label
        diagnostics.requestedFrameRate = selectedMode?.fps
        diagnostics.selectedLens = selectedLens
        diagnostics.requestedShutter = shutter.label
        diagnostics.exposureControlMode = controls.manualExposure ? "customExposure" : "continuousAutoExposureWithDurationLimit"
        diagnostics.requestedMaximumExposureDurationSeconds = shutter.durationSeconds
        do {
            try JSONEncoder.pretty.encode(diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
            guard error == nil, motion.error == nil, frames > 0 else {
                throw RecorderError.unavailable(error ?? motion.error ?? "No video frames written")
            }
            let mode = recordingOutputMode
            let retainDebug = recordingDebugFiles
            try await Task.detached(priority: .userInitiated) {
                try RecordingFinalizer.finalize(folder: folder, clock: clock, outputMode: mode, retainDebugFiles: retainDebug)
            }.value
            state = .completed
            elapsedSeconds = 0
            message = "Saved \(folder.lastPathComponent)"
            if recordingOutputMode == .gcsv || recordingDebugFiles {
                DiagnosticsCollector.record("completed actualFrames=\(frames) imuEvents=\(motion.count)", folder: folder)
            }
        } catch {
            state = .failed
            message = "Recording retained for diagnosis: \(error.localizedDescription)"
            let diagnosticsURL = folder.appendingPathComponent("diagnostics.json")
            if let data = try? Data(contentsOf: diagnosticsURL),
               var failed = try? JSONDecoder().decode(RecordingDiagnostics.self, from: data) {
                failed.status = "failed"
                failed.captureError = error.localizedDescription
                try? JSONEncoder.pretty.encode(failed).write(to: diagnosticsURL)
            }
            DiagnosticsCollector.record("finalization failed reason=\(error.localizedDescription)", folder: folder)
        }
        imuRateLabel = "\(motion.count) events"
        refreshRecordings()
        currentFolder = nil
    }

    func refreshRecordings() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let roots = [documents, selectedSSDFolder.map(RecordingStorage.ssdRoot(in:)),
                     selectedSSDFolder?.appendingPathComponent(RecordingStorage.appFolderName)].compactMap { $0 }
        recordings = roots.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
            .filter { $0.lastPathComponent.hasPrefix("recording_") || $0.lastPathComponent.hasPrefix("GyroCine_") || $0.lastPathComponent.hasPrefix("SteadyCine_") }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

extension JSONEncoder {
    static var pretty: JSONEncoder {
        let result = JSONEncoder()
        result.outputFormatting = [.prettyPrinted, .sortedKeys]
        return result
    }
}
