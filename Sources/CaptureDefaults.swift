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

/// Save dimensions rather than a device-format index, which can change after an OS update.
struct SavedCaptureConfiguration: Codable, Equatable {
    let lensID: String
    let encoding: String
    let width: Int32
    let height: Int32
    let fps: Double
    static let key = "capture.lastSuccessfulConfiguration.v1"
    func save(_ preferences: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        preferences.set(data, forKey: Self.key)
    }
    static func load(_ preferences: UserDefaults = .standard) -> Self? {
        guard let data = preferences.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.width > 0, value.height > 0, value.fps.isFinite, value.fps > 0,
              VideoEncoding(rawValue: value.encoding) != nil else { return nil }
        return value
    }
}

struct SavedCameraControls: Codable, Equatable {
    var shutter = "autoMax"
    var seconds = 1.0 / 120
    var iso = 100.0
    var angle = 180.0
    var maximumSeconds: Double? = nil
    var ev = 0.0
    var whiteBalance = "Auto"
    var kelvin: Float? = nil
    var focus = "Continuous AF"
    var focusPosition: Float = 0.5
    var focusX: Double = 0.5
    var focusY: Double = 0.5
    static let key = "capture.controls.v1"
    func save(_ preferences: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { preferences.set(data, forKey: Self.key) }
    }
    static func load(_ preferences: UserDefaults = .standard) -> Self {
        guard let data = preferences.data(forKey: key),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }
}
