import Foundation

/// One-time migration from the legacy app's settings, without touching recordings.
enum CaptureDefaults {
    static let version = 1
    static func restoreIfNeeded(_ preferences: UserDefaults = .standard) {
        guard preferences.integer(forKey: "rebuildDefaultsVersion") < version else { return }
        for key in preferences.dictionaryRepresentation().keys where key.hasPrefix("capture.") {
            preferences.removeObject(forKey: key)
        }
        preferences.set("内部文件", forKey: "storageLocation")
        preferences.set("SonyMov", forKey: "outputFormat")
        preferences.set(false, forKey: "debugEnabled")
        preferences.set(version, forKey: "rebuildDefaultsVersion")
    }
    static func maximumExposure(fps: Double, minimum: Double, maximum: Double) -> Double {
        exposure(forShutterAngle: 180, fps: fps, minimum: minimum, maximum: maximum)
    }

    static func exposure(forShutterAngle angle: Double, fps: Double,
                         minimum: Double, maximum: Double) -> Double {
        let frameDuration = 1 / max(fps, 1)
        return min(max(frameDuration * min(max(angle, 1), 360) / 360, minimum),
                   maximum, frameDuration)
    }
    static func clampedManualExposure(_ seconds: Double, fps: Double,
                                       minimum: Double, maximum: Double) -> Double {
        min(max(seconds, minimum), maximum, 1 / max(fps, 1))
    }
}
