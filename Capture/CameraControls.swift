import AVFoundation

struct CameraControls: Equatable {
    var manualExposure = false
    var exposureSeconds = 1.0 / 60
    var iso: Float = 100
    var automaticWhiteBalance = true
    var temperature: Float = 5600
    var tint: Float = 0
    static func clamped(_ value: Float, minimum: Float, maximum: Float) -> Float {
        min(maximum, max(minimum, value.isFinite ? value : minimum))
    }
    func apply(to device: AVCaptureDevice, fps: Int, shutter: ShutterSetting, raw: Bool) throws {
        if manualExposure {
            guard device.isExposureModeSupported(.custom) else { throw RecorderError.unavailable("此镜头不支持手动曝光") }
            let duration = min(min(device.activeFormat.maxExposureDuration.seconds, 1 / Double(fps)),
                               max(device.activeFormat.minExposureDuration.seconds, exposureSeconds))
            device.setExposureModeCustom(duration: CMTime(seconds: duration, preferredTimescale: 1_000_000),
                iso: Self.clamped(iso, minimum: device.activeFormat.minISO, maximum: device.activeFormat.maxISO), completionHandler: nil)
        } else {
            device.exposureMode = .continuousAutoExposure
            device.activeMaxExposureDuration = shutter.durationSeconds.map { CMTime(seconds: $0, preferredTimescale: 1_000_000) } ?? .invalid
        }
        if automaticWhiteBalance && !raw && device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        } else {
            guard device.isWhiteBalanceModeSupported(.locked) else { throw RecorderError.unavailable("此镜头不支持锁定白平衡") }
            var gains = automaticWhiteBalance ? device.deviceWhiteBalanceGains : device.deviceWhiteBalanceGains(for: .init(temperature: temperature, tint: tint))
            gains.redGain = Self.clamped(gains.redGain, minimum: 1, maximum: device.maxWhiteBalanceGain)
            gains.greenGain = Self.clamped(gains.greenGain, minimum: 1, maximum: device.maxWhiteBalanceGain)
            gains.blueGain = Self.clamped(gains.blueGain, minimum: 1, maximum: device.maxWhiteBalanceGain)
            device.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
        }
    }
}

enum RecordingColorSpace: String, CaseIterable, Identifiable {
    case rec709, p3, hlg, appleLog
    var id: String { rawValue }
    var label: String { switch self {
        case .rec709: "SDR / Rec.709"
        case .p3: "Display P3"
        case .hlg: "HDR HLG / BT.2020"
        case .appleLog: "Apple Log"
    } }
    var captureSpace: AVCaptureColorSpace { switch self {
        case .rec709: .sRGB
        case .p3: .P3_D65
        case .hlg: .HLG_BT2020
        case .appleLog: .appleLog
    } }
}
