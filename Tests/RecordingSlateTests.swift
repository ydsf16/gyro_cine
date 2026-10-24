import XCTest
import AVFoundation
import CoreLocation
@testable import GyroCine

final class RecordingSlateTests: XCTestCase {
    func testLocationConsentFreshnessAndFormatting() {
        let now = Date()
        func point(age: Double = 0, accuracy: Double = 10) -> CLLocation {
            CLLocation(coordinate: CLLocationCoordinate2D(latitude: 51.5, longitude: -0.125),
                       altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: -1,
                       timestamp: now.addingTimeInterval(-age))
        }
        func items(_ location: CLLocation?, enabled: Bool = true, authorized: Bool = true) -> [AVMetadataItem] {
            RecordingLocation.metadata(location, enabled: enabled, authorized: authorized, now: now)
        }
        XCTAssertEqual(items(point()).first?.stringValue, "+51.50000-000.12500/")
        XCTAssertTrue(items(point(), enabled: false).isEmpty)
        XCTAssertTrue(items(point(), authorized: false).isEmpty)
        XCTAssertTrue(items(nil).isEmpty)
        XCTAssertTrue(items(point(age: 61)).isEmpty)
        XCTAssertTrue(items(point(age: -6)).isEmpty)
        XCTAssertTrue(items(point(accuracy: -1)).isEmpty)
        XCTAssertFalse(items(point(accuracy: 5000)).isEmpty) // Honor approximate-location permission.
    }

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

    func testLegacySlateWithoutNotesStillLoads() throws {
        let original = RecordingSlate()
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        fields.removeValue(forKey: "notes")
        let restored = try JSONDecoder().decode(RecordingSlate.self, from: JSONSerialization.data(withJSONObject: fields))
        XCTAssertEqual(restored.camera, original.camera)
        XCTAssertNil(restored.notes)
    }

    func testProAppsSlateAliasesAndBinaryRAWMetadataSurviveMerge() {
        var slate = RecordingSlate()
        slate.camera = "B"; slate.reel = 2; slate.scene = 3; slate.take = 4
        slate.notes = "测试 / notes"
        let fields = Dictionary(uniqueKeysWithValues: slate.metadata.map { ($0.key as! String, $0.stringValue ?? "") })
        XCTAssertEqual(fields["com.apple.proapps.cameraName"], "B")
        XCTAssertEqual(fields["com.apple.proapps.reel"], "2")
        XCTAssertEqual(fields["com.apple.proapps.scene"], "3")
        XCTAssertEqual(fields["com.apple.proapps.shot"], "4")
        XCTAssertEqual(fields["com.apple.proapps.logNote"], "测试 / notes")
        let calibration = AVMutableMetadataItem()
        calibration.keySpace = .quickTimeMetadata
        calibration.key = "com.apple.proresraw.whitebalance.bycct.colormatrices" as NSString
        calibration.value = Data([0, 1, 255, 128]) as NSData
        calibration.dataType = kCMMetadataBaseDataType_RawData as String
        let system = [calibration] + RecordingMetadata.items(["com.apple.quicktime.model": "System camera"])
        let merged = RecordingMetadata.merging(system, with: slate.metadata + RecordingMetadata.items([
            "com.apple.quicktime.model": "Fallback", "com.apple.proapps.manufacturer": "Apple Inc."]))
        XCTAssertEqual(merged.first { $0.key as? String == calibration.key as? String }?.dataValue, Data([0, 1, 255, 128]))
        XCTAssertEqual(merged.first { $0.key as? String == "com.apple.quicktime.model" }?.stringValue, "System camera")
    }

    func testMetadataMergePreservesRAWCalibration() {
        let system = RecordingMetadata.items(["com.apple.quicktime.software": "old", "org.smpte.camera.matrix": "calibration"])
        let custom = RecordingMetadata.items(["com.apple.quicktime.software": "new"])
        let merged = RecordingMetadata.merging(system, with: custom)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged.contains { $0.stringValue == "calibration" })
        XCTAssertTrue(merged.contains { $0.stringValue == "new" })
        XCTAssertFalse(merged.contains { $0.stringValue == "old" })
    }

    func testMovieInformationRoundTrip() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var slate = RecordingSlate(); slate.notes = "测试备注 / Notes"; slate.scene = 7
        let capture: [String: Any] = ["model": "Test camera", "lensName": "Main", "lensType": "WideAngle",
            "iso": 100, "aperture": 1.8, "exposureSeconds": 1.0 / 60, "whiteBalanceKelvin": 5600,
            "tint": -3, "zoom": 1, "colorSpace": "Rec.709", "scope": "recordingStart"]
        let json = String(data: try JSONSerialization.data(withJSONObject: capture), encoding: .utf8)!
        writer.metadata = slate.metadata + RecordingLocation.metadata(
            CLLocation(latitude: 51.5, longitude: -0.125), enabled: true, authorized: true) + RecordingMetadata.items([
            RecordingMetadata.snapshotKey: json, "com.apple.quicktime.creationdate": "2026-10-24T09:30:00+08:00"])
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 64, AVVideoHeightKey: 32])
        input.transform = CGAffineTransform(rotationAngle: .pi / 2)
        writer.add(input)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input,
            sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 32])
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        for frame in 0..<3 {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer), kCVReturnSuccess)
            CVPixelBufferLockBaseAddress(buffer!, [])
            memset(CVPixelBufferGetBaseAddress(buffer!), 0, CVPixelBufferGetDataSize(buffer!))
            CVPixelBufferUnlockBaseAddress(buffer!, [])
            let deadline = Date().addingTimeInterval(5)
            while !input.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            XCTAssertTrue(input.isReadyForMoreMediaData)
            XCTAssertTrue(adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let info = try await MovieInformationLoader.shared.load(url)
        XCTAssertEqual(info.slate[RecordingLocation.metadataKey], "+51.50000-000.12500/")
        XCTAssertEqual(info.codec, "H.264")
        XCTAssertEqual(info.resolution, "32 × 64")
        XCTAssertEqual(info.model, "Test camera")
        XCTAssertEqual(info.iso, "100")
        XCTAssertEqual(info.shutter, "1/60 s")
        XCTAssertEqual(info.whiteBalance, "5600 K")
        XCTAssertEqual(info.tint, "-3.0")
        XCTAssertEqual(info.slate["com.apple.quicktime.description"], "测试备注 / Notes")
        XCTAssertEqual(info.slate["com.apple.quicktime.scene"], "7")
        let persisted = try await AVURLAsset(url: url).load(.metadata)
        XCTAssertEqual(persisted.first { $0.key as? String == "com.apple.proapps.scene" }?.stringValue, "7")
        XCTAssertNotNil(info.date)
        XCTAssertFalse(info.imu)
    }
}
