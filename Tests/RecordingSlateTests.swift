import XCTest
import AVFoundation
@testable import GyroCine

final class RecordingSlateTests: XCTestCase {
    func testBMCNamingAndCollision() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var slate = RecordingSlate()
        slate.camera = "a/../"; slate.reel = 12
        let date = ISO8601DateFormatter().date(from: "2026-10-17T08:25:00Z")!
        XCTAssertEqual(slate.filename(date: date, clip: 3, timeZone: TimeZone(secondsFromGMT: 8 * 3600)!), "A012_10171625_C003.mov")
        let first = slate.reserveURL(in: directory, date: date, defaults: defaults)
        try Data().write(to: first)
        defaults.set(1, forKey: "slate.nextClip")
        let second = slate.reserveURL(in: directory, date: date, defaults: defaults)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(second.lastPathComponent.hasSuffix("C002.mov"))
        slate.camera = "../../中文"
        XCTAssertEqual(slate.cameraID, "A")
    }
    func testSnapshotAndAutoTake() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        var original = RecordingSlate(); original.director = "导演"; original.take = 7
        original.save(defaults)
        let snapshot = RecordingSlate.load(defaults)
        snapshot.advanceTake(defaults)
        XCTAssertEqual(RecordingSlate.load(defaults).take, 8)
        XCTAssertEqual(snapshot.take, 7)
        snapshot.advanceTake(defaults)
        XCTAssertEqual(RecordingSlate.load(defaults).take, 8)
        XCTAssertTrue(snapshot.metadata.contains { $0.stringValue == "导演" })
        original.autoTake = false; original.save(defaults); original.advanceTake(defaults)
        XCTAssertEqual(RecordingSlate.load(defaults).take, 7)
    }
}
