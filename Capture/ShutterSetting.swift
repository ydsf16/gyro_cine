import AVFoundation

enum ShutterSetting: Int, CaseIterable, Identifiable {
    case auto = 0
    case oneThirtieth = 30
    case oneSixtieth = 60
    case oneOneTwentieth = 120
    case oneTwoFortieth = 240

    var id: Int { rawValue }
    var label: String { self == .auto ? "自动" : "1/\(rawValue) 秒" }
    var durationSeconds: Double? { self == .auto ? nil : 1.0 / Double(rawValue) }

    func isSupported(by device: AVCaptureDevice, mode: CameraMode) -> Bool {
        guard let durationSeconds else { return true }
        let format = device.formats[mode.formatIndex]
        return device.isExposureModeSupported(.custom)
            && durationSeconds >= format.minExposureDuration.seconds - 0.00001
            && durationSeconds <= min(format.maxExposureDuration.seconds, 1.0 / Double(mode.fps)) + 0.00001
    }
}
