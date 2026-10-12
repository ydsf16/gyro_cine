import AVFoundation
import SwiftUI
import UIKit

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var formats: [FormatInfo] = []
    @Published private(set) var codecs: [AVVideoCodecType] = []
    @Published private(set) var selectedCodec: AVVideoCodecType?
    @Published private(set) var selectedFormatIndex: Int?
    @Published private(set) var fps: Double = 30
    @Published private(set) var focusChoice: FocusChoice = .continuous
    @Published private(set) var adjusting = false
    @Published private(set) var lensPosition: Float = 0
    @Published private(set) var actualFocusMode = "Unknown"
    @Published private(set) var recording = false
    @Published private(set) var status = "Requesting camera permission"
    @Published private(set) var errorText: String?
    @Published private(set) var exportURL: URL?
    @Published private(set) var lenses: [LensChoice] = []
    @Published private(set) var selectedLensID: String?
    @Published private(set) var switchingLens = false

    let session = AVCaptureSession()
    let logger = DiagnosticLogger()
    private let queue = DispatchQueue(label: "RAWFocusTest.camera")
    private let output = AVCaptureMovieFileOutput()
    private var device: AVCaptureDevice?
    private var formatObjects: [FormatInfo] = []
    private var chosenCodec: AVVideoCodecType?
    private var chosenIndex: Int?
    private var chosenFPS: Double = 30
    private var chosenFocus: FocusChoice = .continuous
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private struct LensState {
        let formats: [FormatInfo]
        let codecs: [AVVideoCodecType]
        let codec: AVVideoCodecType?
        let formatIndex: Int?
        let fps: Double
    }
    private var lensStates: [String: LensState] = [:]
    private var observations: [NSKeyValueObservation] = []
    private var sampleTimer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var currentFile: URL?
    private var recordingStarting = false

    override init() {
        super.init()
        logger.event("app_launch", ["model": Self.hardwareModel(), "systemName": UIDevice.current.systemName,
                                    "systemVersion": UIDevice.current.systemVersion])
        observeSessionEvents()
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
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            fail("Rear physical Wide camera unavailable"); return
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
            if audioAllowed, let microphone = AVCaptureDevice.default(for: .audio) {
                let audioInput = try AVCaptureDeviceInput(device: microphone)
                guard session.canAddInput(audioInput) else {
                    session.commitConfiguration(); fail("Cannot add microphone input"); return
                }
                session.addInput(audioInput)
            }
            session.commitConfiguration()
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
            discoverCapabilities(camera)
            startSampling(camera)
            session.startRunning()
            publish { self.status = "Camera ready" }
        } catch { fail("Camera setup: \(error)") }
    }

    func chooseLens(_ id: String) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting else {
                self.fail("Lens cannot change during recording"); return
            }
            guard let current = self.device, current.uniqueID != id,
                  let next = self.lensDevices[id],
                  let oldInput = self.session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first else { return }
            self.publish { self.switchingLens = true }
            self.lensStates[current.uniqueID] = LensState(formats: self.formatObjects,
                codecs: self.codecs, codec: self.chosenCodec, formatIndex: self.chosenIndex, fps: self.chosenFPS)
            self.logger.event("lens_switch_request", ["from": current.uniqueID, "to": id,
                "before": self.configurationSnapshot()])
            do {
                let newInput = try AVCaptureDeviceInput(device: next)
                self.session.beginConfiguration()
                self.session.removeInput(oldInput)
                guard self.session.canAddInput(newInput) else {
                    self.session.addInput(oldInput)
                    self.session.commitConfiguration()
                    throw CameraError.unsupportedFocus("Camera input unavailable")
                }
                self.session.addInput(newInput)
                self.session.commitConfiguration()
                self.observations.removeAll()
                self.sampleTimer?.cancel(); self.sampleTimer = nil
                self.device = next
                self.installFocusObservers(next)
                self.startSampling(next)
                if let saved = self.lensStates[id] {
                    self.formatObjects = saved.formats
                    self.codecs = saved.codecs
                    self.chosenCodec = saved.codec
                    self.chosenIndex = saved.formatIndex
                    self.chosenFPS = saved.fps
                    // Re-adding an input can reset its active frame durations. Reapply the
                    // saved format, FPS and codec together before reporting the switch done.
                    guard let index = saved.formatIndex,
                          self.applyFormat(index, reason: "lens_restore") else {
                        throw CameraError.unsupportedFocus("Saved lens format could not be restored")
                    }
                    self.publish {
                        self.formats = saved.formats; self.codecs = saved.codecs
                        self.selectedCodec = saved.codec; self.selectedFormatIndex = saved.formatIndex
                        self.fps = saved.fps
                    }
                } else {
                    self.discoverCapabilities(next)
                }
                self.logger.event("lens_switch_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish {
                    self.selectedLensID = id
                    self.actualFocusMode = self.focusName(next.focusMode)
                    self.lensPosition = next.lensPosition
                    self.switchingLens = false
                }
            } catch {
                self.logger.event("lens_switch_result", ["success": false, "error": String(describing: error)])
                self.publish { self.switchingLens = false }
                self.fail("Lens switch: \(error)")
            }
        }
    }

    private func discoverCapabilities(_ camera: AVCaptureDevice) {
        let oldFormat = camera.activeFormat
        let oldMin = camera.activeVideoMinFrameDuration
        let oldMax = camera.activeVideoMaxFrameDuration
        var found: [FormatInfo] = []
        var union: [AVVideoCodecType] = []
        session.beginConfiguration()
        defer {
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
                let available = output.availableVideoCodecTypes
                info.compatibleCodecs = Set(available.map(\.rawValue))
                for codec in available where !union.contains(codec) { union.append(codec) }
                logger.event("format_probe", ["index": index, "availableCodecs": available.map(\.rawValue)])
            } catch {
                logger.event("format_probe_error", ["index": index, "error": String(describing: error)])
            }
            found.append(info)
        }
        formatObjects = found
        let preferred = union.first(where: { $0 == .hevc }) ?? union.first
        chosenCodec = preferred
        let originalIndex = found.firstIndex(where: { $0.format === oldFormat })
        chosenIndex = originalIndex.flatMap { found[$0].compatibleCodecs.contains(preferred?.rawValue ?? "") ? $0 : nil }
            ?? found.firstIndex(where: { $0.compatibleCodecs.contains(preferred?.rawValue ?? "") })
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
        logger.event("capability_summary", ["formatCount": found.count, "codecs": union.map(\.rawValue),
                                            "reportPath": logger.capabilityURL.path])
        publish {
            self.formats = found; self.codecs = union; self.selectedCodec = preferred
            self.selectedFormatIndex = self.chosenIndex
        }
        // Apply the chosen format after the probe has restored its original state.
        queue.async { if let index = self.chosenIndex { self.applyFormat(index, reason: "initial_selection") } }
    }

    func chooseCodec(_ codec: AVVideoCodecType) {
        queue.async {
            guard !self.output.isRecording else { self.fail("Codec cannot change during recording"); return }
            guard self.codecs.contains(codec) else { self.fail("Codec unavailable: \(codec.rawValue)"); return }
            let before = self.configurationSnapshot()
            let target = self.chosenIndex.flatMap { self.formatObjects[$0].compatibleCodecs.contains(codec.rawValue) ? $0 : nil }
                ?? self.formatObjects.firstIndex(where: { $0.compatibleCodecs.contains(codec.rawValue) })
            self.logger.event("codec_request", ["requested": codec.rawValue, "before": before])
            guard let target else { self.fail("No compatible format for \(codec.rawValue)"); return }
            let previousCodec = self.chosenCodec
            self.chosenCodec = codec
            if !self.applyFormat(target, reason: "codec_change") { self.chosenCodec = previousCodec }
        }
    }

    func chooseFormat(_ index: Int) { queue.async { self.applyFormat(index, reason: "format_change") } }

    @discardableResult private func applyFormat(_ index: Int, reason: String) -> Bool {
        guard !output.isRecording else { fail("Format cannot change during recording"); return false }
        guard let camera = device, let codec = chosenCodec, formatObjects.indices.contains(index) else { fail("Invalid format selection"); return false }
        let info = formatObjects[index]
        guard info.compatibleCodecs.contains(codec.rawValue) else { fail("Format [\(index)] does not support \(codec.rawValue)"); return false }
        let before = configurationSnapshot()
        let previousFormat = camera.activeFormat
        let previousMin = camera.activeVideoMinFrameDuration
        let previousMax = camera.activeVideoMaxFrameDuration
        logger.event("configuration_request", ["kind": reason, "requestedCodec": codec.rawValue, "requestedFormat": index, "before": before])
        do {
            session.beginConfiguration()
            defer { session.commitConfiguration() }
            try camera.lockForConfiguration()
            camera.activeFormat = info.format
            let targetFPS = info.supports(chosenFPS) ? chosenFPS : preferredFPS(for: info)
            let duration = CMTime(value: 1_000_000, timescale: CMTimeScale((targetFPS * 1_000_000).rounded()))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
            guard output.availableVideoCodecTypes.contains(codec), let connection = output.connection(with: .video) else {
                throw CameraError.unavailableCodec(codec.rawValue, index)
            }
            output.setOutputSettings([AVVideoCodecKey: codec.rawValue], for: connection)
            chosenIndex = index; chosenFPS = targetFPS
            logger.event("configuration_result", ["kind": reason, "success": true, "after": configurationSnapshot()])
            publish { self.selectedCodec = codec; self.selectedFormatIndex = index; self.fps = targetFPS; self.errorText = nil }
            return true
        } catch {
            do {
                try camera.lockForConfiguration()
                camera.activeFormat = previousFormat
                camera.activeVideoMinFrameDuration = previousMin
                camera.activeVideoMaxFrameDuration = previousMax
                camera.unlockForConfiguration()
            } catch { logger.event("configuration_rollback_error", ["error": String(describing: error)]) }
            logger.event("configuration_result", ["kind": reason, "success": false, "error": String(describing: error), "after": configurationSnapshot()])
            fail("Format configuration: \(error)")
            return false
        }
    }

    func chooseFPS(_ value: Double) {
        queue.async {
            guard !self.output.isRecording else { self.fail("FPS cannot change during recording"); return }
            guard let camera = self.device, let index = self.chosenIndex, self.formatObjects[index].supports(value) else {
                self.fail("FPS \(value) is unsupported by selected format"); return
            }
            let before = self.configurationSnapshot()
            let previousMin = camera.activeVideoMinFrameDuration
            let previousMax = camera.activeVideoMaxFrameDuration
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
                self.chosenFPS = value
                self.logger.event("fps_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish { self.fps = value; self.errorText = nil }
            } catch {
                self.logger.event("fps_result", ["success": false, "error": String(describing: error), "after": self.configurationSnapshot()])
                self.fail("FPS configuration: \(error)")
            }
        }
    }

    private func preferredFPS(for format: FormatInfo) -> Double {
        [30, 29.97, 24, 60, 25, 23.976, 59.94, 120, 240].first(where: format.supports)
            ?? format.format.videoSupportedFrameRateRanges.first?.maxFrameRate ?? 30
    }

    var availableFPS: [Double] {
        guard let index = selectedFormatIndex, formats.indices.contains(index) else { return [] }
        let common = [23.976, 24, 25, 29.97, 30, 59.94, 60, 120, 240].filter(formats[index].supports)
        return common.isEmpty ? formats[index].format.videoSupportedFrameRateRanges.map(\.maxFrameRate) : common
    }

    private func configurationSnapshot() -> [String: Any] {
        guard let camera = device else { return [:] }
        return ["selectedCodec": chosenCodec?.rawValue ?? "none", "selectedFormat": chosenIndex ?? -1,
                "selectedFPS": chosenFPS, "actualFormat": camera.formats.firstIndex(where: { $0 === camera.activeFormat }) ?? -1,
                "minFrameDurationSeconds": CMTimeGetSeconds(camera.activeVideoMinFrameDuration),
                "maxFrameDurationSeconds": CMTimeGetSeconds(camera.activeVideoMaxFrameDuration),
                "focusMode": focusName(camera.focusMode), "adjustingFocus": camera.isAdjustingFocus,
                "lensPosition": camera.lensPosition,
                "outputSettings": output.connection(with: .video).map { output.outputSettings(for: $0) } ?? [:]]
    }

    private func focusName(_ mode: AVCaptureDevice.FocusMode) -> String {
        switch mode { case .continuousAutoFocus: return "continuousAutoFocus"; case .autoFocus: return "autoFocus"; case .locked: return "locked"; @unknown default: return "unknown" }
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
                case .locked, .manual: .locked
                }
                guard camera.isFocusModeSupported(desired) else { throw CameraError.unsupportedFocus(choice.rawValue) }
                if let point {
                    guard camera.isFocusPointOfInterestSupported else { throw CameraError.unsupportedFocus("focus point") }
                    camera.focusPointOfInterest = point
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
                self.logger.event("focus_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish { self.focusChoice = choice; self.errorText = nil }
            } catch {
                self.logger.event("focus_command_error", ["error": String(describing: error), "after": self.configurationSnapshot()])
                self.fail("Focus: \(error)")
            }
        }
    }

    func tapFocus(_ point: CGPoint) { chooseFocus(.tap, point: point) }
    func setManualPosition(_ value: Float) { chooseFocus(.manual, manualPosition: value) }
    func mark() { queue.async { self.logger.event("mark", ["state": self.configurationSnapshot(), "recording": self.output.isRecording]) } }

    func toggleRecording() {
        queue.async {
            if self.output.isRecording {
                self.logger.event("record_stop_request", ["state": self.configurationSnapshot()])
                if let exception = RecordingExceptionCatcher.exceptionMessage(for: { self.output.stopRecording() }) {
                    self.logger.event("record_stop_exception", ["message": exception])
                    self.fail("Stop recording: \(exception)")
                }
                return
            }
            if self.recordingStarting {
                self.logger.event("record_start_pending")
                return
            }
            guard self.session.isRunning else { self.fail("Camera session is not running"); return }
            guard let codec = self.chosenCodec, let index = self.chosenIndex,
                  self.formatObjects[index].compatibleCodecs.contains(codec.rawValue),
                  self.output.availableVideoCodecTypes.contains(codec) else {
                self.fail("Current codec/format combination is unavailable for recording"); return
            }
            let directory = self.logger.sessionURL.deletingLastPathComponent()
            let url = directory.appendingPathComponent("recording-\(UUID().uuidString).mov")
            self.currentFile = url
            self.logger.event("record_before_start", ["path": url.path, "state": self.configurationSnapshot()])
            self.recordingStarting = true
            if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                self.output.startRecording(to: url, recordingDelegate: self)
            }) {
                self.recordingStarting = false
                self.logger.event("record_start_exception", ["message": exception, "state": self.configurationSnapshot()])
                self.fail("Start recording: \(exception)")
                return
            }
            self.logger.event("record_after_start_call", ["state": self.configurationSnapshot(), "outputIsRecording": self.output.isRecording])
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        queue.async {
            self.recordingStarting = false
            self.logger.event("record_delegate_start", ["path": fileURL.path, "state": self.configurationSnapshot(),
                                                        "outputIsRecording": self.output.isRecording])
            self.publish { self.recording = true }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.recordingStarting = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            self.logger.event("record_delegate_finish", ["path": fileURL.path,
                "fileBytes": attributes?[.size] as? NSNumber ?? 0, "error": error.map { String(describing: $0) } ?? "",
                "state": self.configurationSnapshot()])
            self.publish { self.recording = false; if let error { self.errorText = "Recording failed: \(error)" } }
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
            self.logger.event("focus_sample", ["focusMode": self.focusName(camera.focusMode),
                                                "adjusting": camera.isAdjustingFocus, "lensPosition": camera.lensPosition,
                                                "recording": self.output.isRecording])
        }
        timer.resume(); sampleTimer = timer
    }

    private func observeSessionEvents() {
        let center = NotificationCenter.default
        for name in [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.interruptionEndedNotification,
                     AVCaptureSession.runtimeErrorNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification] {
            notificationTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                self.queue.async {
                    self.logger.event("lifecycle", ["name": name.rawValue,
                                                    "error": note.userInfo?[AVCaptureSessionErrorKey].map { String(describing: $0) } ?? ""])
                    if name == UIApplication.didEnterBackgroundNotification, self.output.isRecording { self.output.stopRecording() }
                    if name == UIApplication.willEnterForegroundNotification || name == AVCaptureSession.interruptionEndedNotification {
                        if !self.session.isRunning { self.session.startRunning() }
                        self.publish { self.status = self.session.isRunning ? "Camera ready" : "Camera interrupted" }
                    }
                    if name == AVCaptureSession.wasInterruptedNotification { self.publish { self.status = "Camera interrupted" } }
                    if name == AVCaptureSession.runtimeErrorNotification { self.fail("Capture session runtime error") }
                }
            })
        }
    }

    func export(_ capability: Bool) {
        logger.flush { self.exportURL = capability ? self.logger.capabilityURL : self.logger.sessionURL }
    }

    func clearError() { publish { self.errorText = nil } }
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
