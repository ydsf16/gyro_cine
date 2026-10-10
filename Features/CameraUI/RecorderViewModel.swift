import Foundation
import SwiftUI
import AVFoundation

@MainActor
final class RecorderViewModel: ObservableObject {
    @Published var state: RecordingState = .idle
    @Published var message: String?
    @Published var audioEnabled = true
    @Published var recordings: [URL] = []
    @Published var imuRateLabel = "pending"
    let coordinator = CaptureCoordinator()
    private let motion = MotionRecorder()
    private var currentFolder: URL?
    private var started = false

    var previewSession: AVCaptureSession { coordinator.session }
    var modes: [CameraMode] {
        guard let device = CameraCapabilityScanner.mainCamera() else { return [] }
        return CameraCapabilityScanner.hevcModes(device: device)
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
    }

    func prepare() {
        guard !started else { return }
        started = true
        refreshRecordings()
        coordinator.configure(audio: audioEnabled)
    }

    func start() {
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
            DiagnosticsCollector.record("start requested codec=HEVC video=3840x2160@30 audio=\(audioEnabled)", folder: folder)
            try motion.start(at: folder.appendingPathComponent("imu_raw.jsonl"))
            coordinator.start(at: folder.appendingPathComponent("clip.mov"))
        } catch {
            state = .failed
            message = error.localizedDescription
        }
    }

    func stop() { coordinator.stop() }

    func retry() {
        currentFolder = nil
        coordinator.configure(audio: audioEnabled)
    }

    private func recordFailure(_ reason: String) {
        guard let folder = currentFolder else { return }
        let diagnostics = RecordingDiagnostics(deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion, configuredCodec: "HEVC",
            audioEnabled: audioEnabled, requestedVideo: "3840x2160@30",
            submittedFrameCount: 0, motionEventCount: motion.count,
            clock: nil, captureError: reason, status: "failed")
        try? JSONEncoder.pretty.encode(diagnostics).write(to: folder.appendingPathComponent("diagnostics.json"))
        DiagnosticsCollector.record("failed reason=\(reason)", folder: folder)
    }

    private func finish(url: URL, clock: ClockEvidence?, frames: Int, error: String?) {
        motion.stop()
        guard let folder = currentFolder else { return }
        let diagnostics = RecordingDiagnostics(
            deviceModel: UIDevice.current.model,
            systemVersion: UIDevice.current.systemVersion,
            configuredCodec: "HEVC", audioEnabled: audioEnabled, requestedVideo: "3840x2160@30",
            submittedFrameCount: frames, motionEventCount: motion.count,
            clock: clock, captureError: error ?? motion.error,
            status: error == nil && motion.error == nil ? "finalizing" : "failed")
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
