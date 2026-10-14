import AVFoundation
import SwiftUI
import UIKit
import VideoToolbox

final class CameraManager: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
    @Published private(set) var formats: [FormatInfo] = []
    @Published private(set) var codecs: [AVVideoCodecType] = []
    @Published private(set) var selectedCodec: AVVideoCodecType?
    @Published private(set) var selectedEncoding: VideoEncoding = .hevc
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
    @Published private(set) var audioAvailable = false
    @Published private(set) var imuAvailable = false
    @Published private(set) var cameraReady = false
    @Published private(set) var finalizing = false
    @Published private(set) var recordingStartedAt: Date?
    @Published private(set) var exposureSeconds: Double = 1.0 / 60.0
    @Published private(set) var iso: Float = 100
    @Published private(set) var whiteBalanceKelvin: Float = 5600
    @Published private(set) var exposureAuto = true
    @Published private(set) var shutterMode: ShutterMode = .autoMax
    @Published private(set) var shutterMaxSeconds: Double = 1.0 / 120.0
    @Published private(set) var whiteBalanceAuto = true
    @Published private(set) var isoRange: ClosedRange<Double> = 50...3200
    @Published private(set) var exposureRange: ClosedRange<Double> = 1.0 / 1000.0...1.0 / 30.0

    let session = AVCaptureSession()
    let logger = DiagnosticLogger()
    private let queue = DispatchQueue(label: "RAWFocusTest.camera")
    private let output = AVCaptureMovieFileOutput()
    private let intrinsicOutput = AVCaptureVideoDataOutput()
    private let intrinsicRecorder = CameraIntrinsicsRecorder()
    private var intrinsicURL: URL?
    private var device: AVCaptureDevice?
    private var formatObjects: [FormatInfo] = []
    private var chosenCodec: AVVideoCodecType?
    private var chosenEncoding: VideoEncoding = .hevc
    private var chosenIndex: Int?
    private var chosenFPS: Double = 30
    private var shutterMaxCustomized = false
    private var chosenFocus: FocusChoice = .continuous
    private var lensDevices: [String: AVCaptureDevice] = [:]
    private struct CapturePreference {
        let encoding: VideoEncoding
        let width: Int32
        let height: Int32
        let fps: Double
    }
    private var observations: [NSKeyValueObservation] = []
    private var sampleTimer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var currentFile: URL?
    private var recordingStarting = false
    private var imuRecorder: IMURecorder?
    private var movieFirstFrameHost: Double?
    private var recordingLens = ""
    private var audioReady = false
    private var telemetryReadoutTick = 0

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
            intrinsicOutput.alwaysDiscardsLateVideoFrames = true
            intrinsicOutput.automaticallyConfiguresOutputBufferDimensions = false
            intrinsicOutput.deliversPreviewSizedOutputBuffers = false
            intrinsicOutput.setSampleBufferDelegate(intrinsicRecorder, queue: intrinsicRecorder.queue)
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
            }
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
            discoverCapabilities(camera)
            startSampling(camera)
            session.startRunning()
            publish { self.status = "Camera ready"; self.cameraReady = self.session.isRunning }
        } catch { fail("Camera setup: \(error)") }
    }

    private func enableIntrinsicDelivery() {
        guard let connection = intrinsicOutput.connection(with: .video) else { return }
        if connection.isCameraIntrinsicMatrixDeliverySupported && !connection.isCameraIntrinsicMatrixDeliveryEnabled {
            connection.isCameraIntrinsicMatrixDeliveryEnabled = true
        }
    }

    func chooseLens(_ id: String) {
        queue.async {
            guard !self.output.isRecording, !self.recordingStarting else {
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
            let previousFormats = self.formatObjects
            let previousCodecs = self.codecs
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
                guard self.discoverCapabilities(next, preference: preference) else {
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
                        self.formatObjects = previousFormats; self.codecs = previousCodecs
                        self.chosenEncoding = preference.encoding; self.chosenCodec = preference.encoding.codec
                        self.chosenIndex = previousIndex; self.chosenFPS = preference.fps
                        self.installFocusObservers(current); self.startSampling(current)
                        if let previousIndex { _ = self.applyFormat(previousIndex, reason: "lens_rollback") }
                        self.publish { self.formats = previousFormats; self.codecs = previousCodecs; self.selectedLensID = current.uniqueID }
                    }
                }
                self.logger.event("lens_switch_result", ["success": false, "error": String(describing: error)])
                self.publish { self.switchingLens = false }
                self.fail("Lens switch: \(error)")
            }
        }
    }

    @discardableResult private func discoverCapabilities(_ camera: AVCaptureDevice, preference: CapturePreference? = nil) -> Bool {
        let oldFormat = camera.activeFormat
        let oldMin = camera.activeVideoMinFrameDuration
        let oldMax = camera.activeVideoMaxFrameDuration
        var found: [FormatInfo] = []
        var union: [AVVideoCodecType] = []
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
                let available = output.availableVideoCodecTypes
                info.compatibleCodecs = Set(available.map(\.rawValue))
                for codec in available where !union.contains(codec) { union.append(codec) }
                logger.event("format_probe", ["index": index, "availableCodecs": available.map(\.rawValue)])
            } catch {
                logger.event("format_probe_error", ["index": index, "error": String(describing: error)])
            }
            found.append(info)
        }
        restoreProbe()
        formatObjects = found
        let preferences = UserDefaults.standard
        let codecKey = "capture.codec.\(camera.uniqueID)"
        let encodingKey = "capture.encoding.\(camera.uniqueID)"
        let formatKey = "capture.format.\(camera.uniqueID)"
        let fpsKey = "capture.fps.\(camera.uniqueID)"
        let rememberedCodec = preferences.string(forKey: codecKey).map(AVVideoCodecType.init(rawValue:))
        let rememberedEncoding = preferences.string(forKey: encodingKey).flatMap(VideoEncoding.init(rawValue:))
        let preferredEncoding = preference?.encoding ?? rememberedEncoding
            ?? VideoEncoding.allCases.first(where: { $0.codec == rememberedCodec }) ?? .hevc
        let encodingOrder: [VideoEncoding] = switch preferredEncoding {
        case .hevc: [.hevc, .hevcHQ, .proResRAW, .proResRAWHQ]
        case .hevcHQ: [.hevcHQ, .hevc, .proResRAW, .proResRAWHQ]
        case .proResRAW: [.proResRAW, .proResRAWHQ, .hevcHQ, .hevc]
        case .proResRAWHQ: [.proResRAWHQ, .proResRAW, .hevcHQ, .hevc]
        }
        guard let encoding = encodingOrder.first(where: { union.contains($0.codec) }) else {
            fail("No supported video encoding on selected lens"); return false
        }
        chosenEncoding = encoding
        chosenCodec = encoding.codec
        let rememberedIndex = preferences.object(forKey: formatKey) as? Int
        let originalIndex = found.firstIndex(where: { $0.format === oldFormat })
        if let preference {
            chosenFPS = preference.fps
            chosenIndex = closestFormatIndex(in: found, codec: encoding.codec, preference: preference)
        } else {
            chosenIndex = rememberedIndex.flatMap { found.indices.contains($0) && found[$0].compatibleCodecs.contains(encoding.codec.rawValue) ? $0 : nil }
                ?? originalIndex.flatMap { found[$0].compatibleCodecs.contains(encoding.codec.rawValue) ? $0 : nil }
                ?? found.firstIndex(where: { $0.compatibleCodecs.contains(encoding.codec.rawValue) })
            if let chosenIndex, let rememberedFPS = preferences.object(forKey: fpsKey) as? Double,
               found[chosenIndex].supports(rememberedFPS) { chosenFPS = rememberedFPS }
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
        logger.event("capability_summary", ["formatCount": found.count, "codecs": union.map(\.rawValue),
                                            "reportPath": logger.capabilityURL.path])
        publish {
            self.formats = found; self.codecs = union; self.selectedCodec = encoding.codec
            self.selectedEncoding = encoding
            self.selectedFormatIndex = self.chosenIndex
        }
        guard let index = chosenIndex else { fail("No compatible format on selected lens"); return false }
        let applied = applyFormat(index, reason: preference == nil ? "initial_selection" : "lens_switch")
        if applied, let preference {
            logger.event("lens_configuration_fallback", ["requested": [preference.encoding.title, "\(preference.width)×\(preference.height)", preference.fps],
                                                       "chosen": configurationSnapshot()])
        }
        return applied
    }

    func chooseEncoding(_ encoding: VideoEncoding) {
        queue.async {
            guard !self.output.isRecording else { self.fail("Codec cannot change during recording"); return }
            let codec = encoding.codec
            guard self.codecs.contains(codec) else { self.fail("Codec unavailable: \(codec.rawValue)"); return }
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
            let targetFPS = info.supports(chosenFPS) ? chosenFPS : nearestFPS(to: chosenFPS, in: info)
            let duration = CMTime(value: 1_000_000, timescale: CMTimeScale((targetFPS * 1_000_000).rounded()))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
            camera.unlockForConfiguration()
            guard output.availableVideoCodecTypes.contains(codec), let connection = output.connection(with: .video) else {
                throw CameraError.unavailableCodec(codec.rawValue, index)
            }
            enableIntrinsicDelivery()
            let settings = try encodingSettings(for: info, fps: targetFPS, connection: connection)
            if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                self.output.setOutputSettings(settings, for: connection)
            }) { throw CameraError.unsupportedFocus("Encoding settings: \(exception)") }
            if shutterMode == .autoMax {
                let requested = shutterMaxCustomized ? shutterMaxSeconds : 1 / (targetFPS * 4)
                let limit = min(max(requested, CMTimeGetSeconds(info.format.minExposureDuration)),
                                CMTimeGetSeconds(info.format.maxExposureDuration), 1 / targetFPS)
                try camera.lockForConfiguration()
                camera.exposureMode = .continuousAutoExposure
                camera.activeMaxExposureDuration = CMTime(seconds: limit, preferredTimescale: 1_000_000)
                camera.unlockForConfiguration()
                publish { self.shutterMaxSeconds = limit }
            }
            chosenIndex = index; chosenFPS = targetFPS
            if reason != "initial_selection" {
                let preferences = UserDefaults.standard
                preferences.set(codec.rawValue, forKey: "capture.codec.\(camera.uniqueID)")
                preferences.set(chosenEncoding.rawValue, forKey: "capture.encoding.\(camera.uniqueID)")
                preferences.set(index, forKey: "capture.format.\(camera.uniqueID)")
                preferences.set(targetFPS, forKey: "capture.fps.\(camera.uniqueID)")
            }
            logger.event("configuration_result", ["kind": reason, "success": true, "after": configurationSnapshot()])
            publish {
                self.selectedCodec = codec; self.selectedEncoding = self.chosenEncoding
                self.selectedFormatIndex = index; self.fps = targetFPS
                self.isoRange = Double(camera.activeFormat.minISO)...Double(camera.activeFormat.maxISO)
                self.exposureRange = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)...CMTimeGetSeconds(camera.activeFormat.maxExposureDuration)
                self.errorText = nil
            }
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
            guard let camera = self.device, let index = self.chosenIndex,
                  self.formatObjects.indices.contains(index), let codec = self.chosenCodec else {
                self.fail("No active video format"); return
            }
            if !self.formatObjects[index].supports(value) {
                let current = self.formatObjects[index]
                let candidates = self.formatObjects.filter {
                    $0.width == current.width && $0.height == current.height &&
                    $0.compatibleCodecs.contains(codec.rawValue) && $0.supports(value)
                }
                guard let alternate = candidates.min(by: {
                    ($0.format.autoFocusSystem == .none ? 1 : 0,
                     abs($0.index - index)) <
                    ($1.format.autoFocusSystem == .none ? 1 : 0,
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
                if let connection = self.output.connection(with: .video) {
                    let settings = try self.encodingSettings(for: self.formatObjects[index], fps: value, connection: connection)
                    if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                        self.output.setOutputSettings(settings, for: connection)
                    }) { throw CameraError.unsupportedFocus("Encoding settings: \(exception)") }
                }
                if self.shutterMode == .autoMax {
                    self.setExposureAutoMax(seconds: self.shutterMaxCustomized ? self.shutterMaxSeconds : 1 / (value * 4),
                                            customized: false)
                }
                self.chosenFPS = value
                UserDefaults.standard.set(value, forKey: "capture.fps.\(camera.uniqueID)")
                self.logger.event("fps_result", ["success": true, "after": self.configurationSnapshot()])
                self.publish { self.fps = value; self.errorText = nil }
            } catch {
                self.logger.event("fps_result", ["success": false, "error": String(describing: error), "after": self.configurationSnapshot()])
                self.fail("FPS configuration: \(error)")
            }
        }
    }

    private func nearestFPS(to requested: Double, in format: FormatInfo) -> Double {
        let rates = availableFPS(for: format)
        return rates.min { abs($0 - requested) < abs($1 - requested) }
            ?? format.format.videoSupportedFrameRateRanges.first.map { min(max(requested, $0.minFrameRate), $0.maxFrameRate) }
            ?? 30
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
        }
        return formats.indices.filter { formats[$0].compatibleCodecs.contains(codec.rawValue) }
            .min { score(formats[$0]) < score(formats[$1]) }
    }

    private func encodingSettings(for info: FormatInfo, fps: Double, connection: AVCaptureConnection) throws -> [String: Any] {
        guard let codec = chosenCodec else { throw CameraError.unsupportedFocus("Video codec") }
        var settings: [String: Any] = [AVVideoCodecKey: codec.rawValue]
        if chosenEncoding == .hevcHQ {
            guard output.supportedOutputSettingsKeys(for: connection).contains(AVVideoCompressionPropertiesKey) else {
                throw CameraError.unsupportedFocus("HEVC HQ bitrate control")
            }
            let bitrate = Int(min(200_000_000, max(10_000_000,
                Double(info.width) * Double(info.height) * fps * 0.35)))
            settings[AVVideoCompressionPropertiesKey] = [kVTCompressionPropertyKey_AverageBitRate as String: bitrate]
        }
        return settings
    }

    private func availableFPS(for format: FormatInfo) -> [Double] {
        let common = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 119.88, 120, 240].filter(format.supports)
        let rates = common.isEmpty ? format.format.videoSupportedFrameRateRanges.flatMap { [$0.minFrameRate, $0.maxFrameRate] } : common
        return Array(Set(rates)).sorted()
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
                "actualFormat": camera.formats.firstIndex(where: { $0 === camera.activeFormat }) ?? -1,
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

    func tapFocus(_ point: CGPoint) { chooseFocus(.continuous, point: point) }
    func lockFocus(at _: CGPoint) { chooseFocus(.locked) }
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
                } else {
                    guard camera.isExposureModeSupported(.custom) else { throw CameraError.unsupportedFocus("Manual exposure") }
                    camera.setExposureModeCustom(duration: camera.exposureDuration, iso: camera.iso)
                }
                let mode: ShutterMode = enabled ? .auto : .manual
                self.publish { self.exposureAuto = enabled; self.shutterMode = mode }
            } catch { self.fail("Exposure: \(error)") }
        }
    }
    func activateExposureAutoMax() {
        queue.async {
            let requested = self.shutterMaxCustomized ? self.shutterMaxSeconds : 1 / (self.chosenFPS * 4)
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
            let minimum = CMTimeGetSeconds(camera.activeFormat.minExposureDuration)
            let maximum = min(CMTimeGetSeconds(camera.activeFormat.maxExposureDuration), 1 / chosenFPS)
            let limit = min(max(seconds, minimum), maximum)
            camera.exposureMode = .continuousAutoExposure
            camera.activeMaxExposureDuration = CMTime(seconds: limit, preferredTimescale: 1_000_000)
            if customized { shutterMaxCustomized = true }
            logger.event("exposure_auto_max", ["limitSeconds": limit, "state": configurationSnapshot()])
            publish {
                self.shutterMaxSeconds = limit; self.shutterMode = .autoMax; self.exposureAuto = true
            }
        } catch { fail("A-Max: \(error)") }
    }
    func setManualExposure(seconds: Double? = nil, iso: Double? = nil) {
        queue.async {
            guard let camera = self.device, camera.isExposureModeSupported(.custom) else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let range = camera.activeFormat.minExposureDuration...camera.activeFormat.maxExposureDuration
                let requested = CMTime(seconds: seconds ?? CMTimeGetSeconds(camera.exposureDuration), preferredTimescale: 1_000_000)
                let duration = min(max(requested, range.lowerBound), range.upperBound)
                let level = Float(min(max(iso ?? Double(camera.iso), Double(camera.activeFormat.minISO)), Double(camera.activeFormat.maxISO)))
                camera.setExposureModeCustom(duration: duration, iso: level)
                self.publish { self.exposureAuto = false; self.shutterMode = .manual }
            } catch { self.fail("Exposure: \(error)") }
        }
    }
    func setWhiteBalanceAuto(_ enabled: Bool) {
        queue.async {
            guard let camera = self.device else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                if enabled {
                    guard camera.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) else { throw CameraError.unsupportedFocus("Auto white balance") }
                    camera.whiteBalanceMode = .continuousAutoWhiteBalance
                } else {
                    guard camera.isWhiteBalanceModeSupported(.locked) else { throw CameraError.unsupportedFocus("Manual white balance") }
                    camera.whiteBalanceMode = .locked
                }
                self.publish { self.whiteBalanceAuto = enabled }
            } catch { self.fail("White balance: \(error)") }
        }
    }
    func setWhiteBalance(kelvin: Float) {
        queue.async {
            guard let camera = self.device, camera.isWhiteBalanceModeSupported(.locked) else { return }
            do {
                try camera.lockForConfiguration()
                defer { camera.unlockForConfiguration() }
                let values = AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: min(max(kelvin, 2000), 10000), tint: 0)
                let gains = camera.deviceWhiteBalanceGains(for: values)
                let ceiling = camera.maxWhiteBalanceGain
                let safe = AVCaptureDevice.WhiteBalanceGains(redGain: min(max(gains.redGain, 1), ceiling),
                    greenGain: min(max(gains.greenGain, 1), ceiling), blueGain: min(max(gains.blueGain, 1), ceiling))
                camera.setWhiteBalanceModeLocked(with: safe)
                self.publish { self.whiteBalanceAuto = false; self.whiteBalanceKelvin = kelvin }
            } catch { self.fail("White balance: \(error)") }
        }
    }
    func mark() { queue.async { self.logger.event("mark", ["state": self.configurationSnapshot(), "recording": self.output.isRecording]) } }

    func toggleRecording() {
        queue.async {
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
            if self.recordingStarting {
                self.logger.event("record_start_pending")
                return
            }
            guard self.session.isRunning else { self.fail("Camera session is not running"); return }
            guard self.audioReady else { self.fail("需要麦克风权限才能录制声音。请在系统设置中允许麦克风访问。"); return }
            guard let codec = self.chosenCodec, let index = self.chosenIndex,
                  self.formatObjects[index].compatibleCodecs.contains(codec.rawValue),
                  self.output.availableVideoCodecTypes.contains(codec) else {
                self.fail("Current codec/format combination is unavailable for recording"); return
            }
            let directory = self.logger.sessionURL.deletingLastPathComponent()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
            let baseName = "G_\(formatter.string(from: Date()))"
            var url = directory.appendingPathComponent("\(baseName).mov")
            var suffix = 2
            while FileManager.default.fileExists(atPath: url.path) {
                url = directory.appendingPathComponent("\(baseName)-\(suffix).mov")
                suffix += 1
            }
            self.currentFile = url
            let imu = IMURecorder()
            let imuURL = url.deletingPathExtension().appendingPathExtension("imu_raw.jsonl")
            do { try imu.start(at: imuURL) }
            catch { self.fail("IMU 启动失败：\(error.localizedDescription)"); return }
            self.imuRecorder = imu
            self.movieFirstFrameHost = nil
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
                      dataConnection.isCameraIntrinsicMatrixDeliveryEnabled,
                      let movieConnection = self.output.connection(with: .video),
                      movieConnection.activeVideoStabilizationMode == .off,
                      dataConnection.activeVideoStabilizationMode == .off,
                      dataConnection.videoRotationAngle == 0,
                      movieConnection.isVideoMirrored == dataConnection.isVideoMirrored else {
                    throw RecorderError.unavailable("当前配置无法提供与视频一致的真实 K")
                }
                let evidenceURL = url.deletingPathExtension().appendingPathExtension("camera_frames.jsonl")
                try self.intrinsicRecorder.start(at: evidenceURL, clock: self.session.synchronizationClock, camera: camera)
                self.intrinsicURL = evidenceURL
            } catch {
                try? imu.stop(); self.imuRecorder = nil
                self.fail(error.localizedDescription); return
            }
            self.recordingLens = self.device?.localizedName ?? "iPhone camera"
            self.logger.event("record_before_start", ["path": url.path, "state": self.configurationSnapshot()])
            self.recordingStarting = true
            self.startMovieWhenIMUReady(url: url, deadline: ProcessInfo.processInfo.systemUptime + 2)
        }
    }

    private func startMovieWhenIMUReady(url: URL, deadline: Double) {
        let uptime = ProcessInfo.processInfo.systemUptime
        guard let imu = imuRecorder else { recordingStarting = false; return }
        if let gyro = imu.firstGyroTime, let accel = imu.firstAccelTime,
           uptime - max(gyro, accel) >= 0.07 {
            if let exception = RecordingExceptionCatcher.exceptionMessage(for: {
                self.output.startRecording(to: url, recordingDelegate: self)
            }) {
                recordingStarting = false
                try? self.intrinsicRecorder.stop()
                try? imu.stop()
                imuRecorder = nil
                fail("Start recording: \(exception)")
            }
        } else if uptime < deadline {
            queue.asyncAfter(deadline: .now() + 0.01) { self.startMovieWhenIMUReady(url: url, deadline: deadline) }
        } else {
            recordingStarting = false
            try? intrinsicRecorder.stop()
            try? imu.stop(); imuRecorder = nil
            fail("IMU 预录 50 ms 未就绪，录制未开始")
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL,
                    startPTS: CMTime, from connections: [AVCaptureConnection]) {
        queue.async {
            self.recordingStarting = false
            self.movieFirstFrameHost = try? ClockAligner.hostTime(startPTS, clock: self.session.synchronizationClock)
            self.logger.event("record_delegate_start", ["path": fileURL.path, "state": self.configurationSnapshot(),
                "startPTS": startPTS.seconds, "firstHost": self.movieFirstFrameHost ?? -1,
                "outputIsRecording": self.output.isRecording])
            self.publish { self.recording = true; self.recordingStartedAt = Date(); self.finalizing = false }
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        queue.async {
            self.recordingStarting = false
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            self.logger.event("record_delegate_finish", ["path": fileURL.path,
                "fileBytes": attributes?[.size] as? NSNumber ?? 0, "error": error.map { String(describing: $0) } ?? "",
                "state": self.configurationSnapshot()])
            self.publish { self.recording = false; self.finalizing = true; self.recordingStartedAt = nil }
            let imu = self.imuRecorder
            let firstHost = self.movieFirstFrameHost
            let evidenceURL = self.intrinsicURL
            let lens = self.recordingLens
            let mode = UserDefaults.standard.string(forKey: "outputFormat") == "GyroflowProto" ? "GyroflowProto" : "SonyMov"
            let debug = UserDefaults.standard.bool(forKey: "debugEnabled")
            // Capture for at least 50 ms beyond the file-output completion callback.
            self.queue.asyncAfter(deadline: .now() + 0.12) {
                self.imuRecorder = nil
                do {
                    guard let imu, let raw = imu.url else { throw RecorderError.unavailable("IMU 未启动") }
                    let intrinsicStop = Result { try self.intrinsicRecorder.stop() }
                    let imuStop = Result { try imu.stop() }
                    try intrinsicStop.get()
                    try imuStop.get()
                    if let error { throw error }
                    guard let firstHost, let evidenceURL else { throw RecorderError.unavailable("缺少 MOV 首帧时钟映射") }
                    let result = try MovieIMUFinalizer.finalize(movie: fileURL, rawIMU: raw,
                        firstFrameHost: firstHost, cameraFrames: evidenceURL,
                        camera: Self.hardwareModel(), lens: lens, mode: mode, retainDebug: debug)
                    self.logger.event("imu_embedded", ["format": mode, "samples": result.0,
                        "preRollMs": result.1 * 1000, "postRollMs": result.2 * 1000])
                    self.publish { self.finalizing = false; self.status = "Saved · IMU embedded" }
                } catch {
                    self.logger.event("imu_embed_failed", ["error": String(describing: error), "movie": fileURL.path])
                    self.publish {
                        self.finalizing = false
                        self.errorText = "视频已录制，但 IMU 封装失败：\(error.localizedDescription)。原始文件已保留。"
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
            if self.telemetryReadoutTick % 5 == 0 {
                let temperature = camera.temperatureAndTintValues(for: camera.deviceWhiteBalanceGains).temperature
                let iso = camera.iso
                let exposureSeconds = CMTimeGetSeconds(camera.exposureDuration)
                let exposureAuto = camera.exposureMode == .continuousAutoExposure
                let whiteBalanceAuto = camera.whiteBalanceMode == .continuousAutoWhiteBalance
                self.publish {
                    self.iso = iso
                    self.exposureSeconds = exposureSeconds
                    self.whiteBalanceKelvin = temperature
                    self.exposureAuto = exposureAuto
                    self.whiteBalanceAuto = whiteBalanceAuto
                }
            }
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
                        self.publish { self.status = self.session.isRunning ? "Camera ready" : "Camera interrupted"; self.cameraReady = self.session.isRunning }
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
