import XCTest
import AVFoundation
@testable import GyroCine

final class RecordingStorageTests: XCTestCase {
    func testRAWSettingsExceptionBecomesSwiftError() throws {
        let output = AVCaptureVideoDataOutput()
        let invalidCodec = AVVideoCodecType(rawValue: "invalid-test-codec")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("probe.mov")
        XCTAssertThrowsError(try RAWSettingsProbe.settings(output: output, codec: invalidCodec, url: url)) { error in
            XCTAssertEqual((error as NSError).domain, "GyroCine.RAWSettingsProbe")
        }
        if #available(iOS 26.0, *) {
            XCTAssertThrowsError(try RAWSettingsProbe.metadata(output: output, codec: invalidCodec)) { error in
                XCTAssertEqual((error as NSError).domain, "GyroCine.RAWSettingsProbe")
            }
        }
    }

    func testInternalRawProbeWithoutNewSystemSelectorIsSafe() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        if !writer.responds(to: NSSelectorFromString("isProVideoStorageSupported")) &&
           !writer.responds(to: NSSelectorFromString("proVideoStorageSupported")) {
            XCTAssertFalse(RAWInternalStorage.enableProStorageIfSupported(on: writer))
        }
        XCTAssertEqual(writer.status, .unknown)
    }

    func testRecordingNamesAndLegacyCompatibility() {
        let new = URL(fileURLWithPath: "/tmp/GyroCine_20261011_130000", isDirectory: true)
        for ext in ["mov", "gcsv", "gyroflow"] {
            XCTAssertEqual(new.recordingFile(ext).lastPathComponent, "GyroCine_20261011_130000." + ext)
        }
        let old = URL(fileURLWithPath: "/tmp/recording_20261011_120743", isDirectory: true)
        XCTAssertEqual(old.recordingFile("mov").lastPathComponent, "clip.mov")
    }

    func testTelemetryOnlyPublishesAfterCaptureAndPreservesBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("imu.jsonl")
        let log = try StagedRecordingLog(destination: destination)
        try log.write(contentsOf: Data("first\n".utf8))
        try log.write(contentsOf: Data("second\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try log.close()
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try log.publish()
        XCTAssertEqual(try Data(contentsOf: destination), Data("first\nsecond\n".utf8))
    }
    func testSSDCapacityDoesNotUseZeroImportantUsageReading() {
        XCTAssertEqual(RecordingStorage.availableBytes(location: .ssd, external: 800_000_000_000,
            ordinary: 800_000_000_000, important: 0), 800_000_000_000)
        XCTAssertEqual(RecordingStorage.availableBytes(location: .ssd, external: nil,
            ordinary: 800_000_000_000, important: 0), 800_000_000_000)
        XCTAssertEqual(RecordingStorage.availableBytes(location: .ssd, external: 0,
            ordinary: 800_000_000_000, important: 0), 0)
        XCTAssertNil(RecordingStorage.availableBytes(location: .ssd, external: nil, ordinary: nil, important: nil))
    }
    func testFilesLocationUsesTheAppDocumentsFolder() {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(RecordingStorage.filesRoot.standardizedFileURL, documents.standardizedFileURL)
    }

    func testSSDLocationCreatesDCIMAndReusesAuthorizedDCIM() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = try RecordingStorage.createSSDRoot(in: parent)
        XCTAssertEqual(root.lastPathComponent, "DCIM")
        XCTAssertEqual(try RecordingStorage.createSSDRoot(in: root), root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("DCIM").path))
        XCTAssertEqual(root.deletingLastPathComponent().standardizedFileURL, parent.standardizedFileURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }
}
