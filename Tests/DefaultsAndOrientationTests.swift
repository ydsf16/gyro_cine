import XCTest
@testable import GyroCine

final class DefaultsAndOrientationTests: XCTestCase {
    func testGravityDirectionsAndFlatFallback() {
        var tracker = RecordingDirectionTracker()
        XCTAssertEqual(tracker.resolve(nil, at: 100).orientation, .portrait)
        for (x, y, expected) in [(0.0, -1.0, RecordingOrientation.portrait),
                                (-1.0, 0.0, .landscapeRight), (0.0, 1.0, .portraitUpsideDown),
                                (1.0, 0.0, .landscapeLeft)] {
            XCTAssertEqual(tracker.resolve(.init(timestamp: 100, x: x, y: y, z: 0), at: 100.1).orientation, expected)
        }
        XCTAssertEqual(tracker.resolve(.init(timestamp: 100, x: 0.02, y: 0.01, z: -1), at: 100.1).orientation, .landscapeLeft)
        XCTAssertEqual(tracker.resolve(.init(timestamp: 90, x: 0, y: -1, z: 0), at: 100).orientation, .landscapeLeft)
    }
    func testExposureDefaultsAcrossFrameRates() {
        for fps in [24.0, 25, 29.97, 30, 59.94, 60, 120] {
            XCTAssertEqual(CaptureDefaults.maximumExposure(fps: fps, minimum: 1/10000, maximum: 1), 1/(fps*4), accuracy: 1e-9)
        }
        XCTAssertEqual(CaptureDefaults.maximumExposure(fps: 120, minimum: 1/300, maximum: 1), 1/300, accuracy: 1e-9)
    }
    func testSettingsMigrationRunsOnce() {
        let suite = "GyroCineTests.\(UUID())"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(120, forKey: "capture.fps.camera")
        preferences.set(true, forKey: "debugEnabled")
        CaptureDefaults.restoreIfNeeded(preferences)
        XCTAssertNil(preferences.object(forKey: "capture.fps.camera"))
        XCTAssertFalse(preferences.bool(forKey: "debugEnabled"))
        XCTAssertEqual(preferences.string(forKey: "outputFormat"), "SonyMov")
        preferences.set(60, forKey: "capture.fps.camera")
        CaptureDefaults.restoreIfNeeded(preferences)
        XCTAssertEqual(preferences.integer(forKey: "capture.fps.camera"), 60)
    }
}
