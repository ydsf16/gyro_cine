import AVFoundation

enum ShutterSetting: Int, CaseIterable, Identifiable {
    case auto = 0
    case oneTwentyFourth = 24
    case oneTwentyFifth = 25
    case oneThirtieth = 30
    case oneFortyEighth = 48
    case oneFiftieth = 50
    case oneSixtieth = 60
    case oneNinetySixth = 96
    case oneHundredth = 100
    case oneOneTwentieth = 120
    case oneOneTwentyFifth = 125
    case oneOneEightieth = 180
    case oneTwoFortieth = 240
    case oneTwoFiftieth = 250
    case oneFiveHundredth = 500
    case oneThousandth = 1000
    case oneTwoThousandth = 2000

    var id: Int { rawValue }
    var label: String { self == .auto ? "系统默认" : "1/\(rawValue) 秒" }
    var durationSeconds: Double? { self == .auto ? nil : 1.0 / Double(rawValue) }

    func isSupported(by device: AVCaptureDevice, mode: CameraMode) -> Bool {
        guard device.formats.indices.contains(mode.formatIndex) else { return false }
        guard let durationSeconds else { return true }
        let format = device.formats[mode.formatIndex]
        return device.isExposureModeSupported(.continuousAutoExposure)
            && durationSeconds >= format.minExposureDuration.seconds - 0.00001
            && durationSeconds <= min(format.maxExposureDuration.seconds, 1.0 / Double(mode.fps)) + 0.00001
    }
}
