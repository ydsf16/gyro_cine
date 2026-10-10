import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var message: String?
    @Published var audioEnabled = true
    @Published var shutter: ShutterSetting = .auto
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
    private var started = false
    private var recordingTimer: Timer?
    private var primingTask: Task<Void, Never>?

    var previewSession: AVCaptureSession { coordinator.session }
    var modes: [CameraMode] {
        guard let device = selectedLens.flatMap({ CameraCapabilityScanner.device(id: $0.id) }) ?? CameraCapabilityScanner.mainCamera() else { return [] }
        return CameraCapabilityScanner.hevcModes(device: device)
    }
    var supportedShutters: [ShutterSetting] {
        guard let device = selectedLens.flatMap({ CameraCapabilityScanner.device(id: $0.id) }),
              let mode = modes.first else { return [.auto] }
        return ShutterSetting.allCases.filter { $0.isSupported(by: device, mode: mode) }
    }
    var capabilityLabel: String { modes.isEmpty ? "4K30 unavailable or camera inaccessible" : "HEVC 4K30 candidate; recording requires verification" }
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
        coordinator.onState = { [weak self] state, message in
            Task { @MainActor in
                self?.state = state
                self?.message = message
                if state == .recording { self?.startStatusTimer() }
                else { self?.recordingTimer?.invalidate(); self?.recordingTimer = nil }
                DiagnosticsCollector.record("state=\(state.rawValue) message=\(message ?? "none")", folder: self?.currentFolder)
                if state == .failed {
                    self?.motion.stop()
                    self?.recordFailure(message ?? "Capture failed")
                    self?.refreshRecordings()
                }
            }
        }
        coordinator.onCompleted = { [weak self] url, clock, frames, error in
            Task { @MainActor in self?.finish(url: url, clock: clock, frames: frames, error: error) }
        }
        coordinator.onExposureReading = { [weak self] duration, iso in
            Task { @MainActor in
                guard duration.isFinite, duration > 0, iso.isFinite else { return }
                self?.exposureReadout = String(format: "实际约 1/%.1f 秒 · ISO %.0f", 1 / duration, iso)
            }
        }
    }

    func prepare() {
        guard !started else { return }
        started = true
        refreshRecordings()
        lenses = CameraCapabilityScanner.lenses()
        selectedLens = lenses.first { $0.deviceType == AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue && $0.supports4K30 }
            ?? lenses.first { $0.supports4K30 }
        reconfigure()
    }

    func selectLens(_ lens: CameraLens) {
        guard canSelectLens, lens.supports4K30, lenses.contains(lens), lens.id != selectedLens?.id else { return }
        selectedLens = lens
        if !supportedShutters.contains(shutter) { shutter = .auto }
        reconfigure()
    }

    func reconfigure() {
        guard state != .recording, state != .finalizing, state != .configuring else { return }
        state = .configuring
        coordinator.configure(audio: audioEnabled, cameraID: selectedLens?.id, shutter: shutter)
    }

    func start() {
        guard state == .ready || state == .completed else { return }
        state = .configuring // Disable lens changes immediately, including before the first video sample.

        do {
            guard motion.isAvailable else { throw RecorderError.unavailable("Raw motion sensors unavailable") }
            let freeBytes = (try? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
            guard freeBytes >= 2_000_000_000 else {
                throw RecorderError.unavailable("At least 2 GB available storage is required for this HEVC recording")
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let date = DateFormatter()
            date.dateFormat = "yyyyMMdd_HHmmss"
            let folder = documents.appendingPathComponent("recording_\(date.string(from: Date()))")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            currentFolder = folder
            DiagnosticsCollector.record("start requested codec=HEVC video=3840x2160@30 audio=\(audioEnabled) shutter=\(shutter.label) lens=\(selectedLens?.name ?? "unknown") multiplier=\(selectedLens?.label ?? "unknown") cameraID=\(selectedLens?.id ?? "unknown")", folder: folder)
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
                self.coordinator.start(at: folder.appendingPathComponent("clip.mov"))
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
            systemVersion: UIDevice.current.systemVersion, configuredCodec: "HEVC",
            audioEnabled: audioEnabled, requestedVideo: "3840x2160@30",
            submittedFrameCount: 0, motionEventCount: motion.count,
            clock: nil, captureError: reason, status: "failed")
        diagnostics.selectedLens = selectedLens
        diagnostics.requestedShutter = shutter.label
        diagnostics.exposureControlMode = "continuousAutoExposureWithDurationLimit"
        diagnostics.requestedMaximumExposureDurationSeconds = shutter.durationSeconds
        try? JSONEncoder.pretty.encode(diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
        DiagnosticsCollector.record("failed reason=\(reason)", folder: folder)
    }

    private func finish(url: URL, clock: ClockEvidence?, frames: Int, error: String?) {
        primingTask?.cancel()
        primingTask = nil
        motion.stop()
        guard let folder = currentFolder else { return }
        var diagnostics = RecordingDiagnostics(
            deviceModel: RecorderIdentity.cameraModel,
            systemVersion: UIDevice.current.systemVersion,
            configuredCodec: "HEVC", audioEnabled: audioEnabled, requestedVideo: "3840x2160@30",
            submittedFrameCount: frames, motionEventCount: motion.count,
            clock: clock, captureError: error ?? motion.error,
            status: error == nil && motion.error == nil ? "finalizing" : "failed")
        diagnostics.selectedLens = selectedLens
        diagnostics.requestedShutter = shutter.label
        diagnostics.exposureControlMode = "continuousAutoExposureWithDurationLimit"
        diagnostics.requestedMaximumExposureDurationSeconds = shutter.durationSeconds
        do {
            try JSONEncoder.pretty.encode(diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
            guard error == nil, motion.error == nil, frames > 0 else {
                throw RecorderError.unavailable(error ?? motion.error ?? "No video frames written")
            }
            try RecordingFinalizer.finalize(folder: folder, clock: clock)
            state = .completed
            message = "Saved \(folder.lastPathComponent)"
            DiagnosticsCollector.record("completed actualFrames=\(frames) imuEvents=\(motion.count)", folder: folder)
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
        recordings = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("recording_") }
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
