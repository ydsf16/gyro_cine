import XCTest
import AVFoundation
@testable import RawMotionRecorder

final class EmbeddedTelemetryTests: XCTestCase {
    func testMetadataAppendPreservesEncodedMediaAndVideoTimeline() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "writer3frames", withExtension: "mov"))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = try Data(contentsOf: fixture)
        let originalAtoms = try MOVTelemetryMuxer.atoms(original)
        let source = try RecordingFinalizer.inspectVideo(fixture)
        for kind in ["rtmd", "gyrf"] {
            let url = folder.appendingPathComponent("\(kind).mov")
            try original.write(to: url)
            try MOVTelemetryMuxer.append(to: url, kind: kind, packets: [Data([1, 2, 3])], durations: [100_000], note: Data())
            let output = try Data(contentsOf: url)
            let atoms = try MOVTelemetryMuxer.atoms(output)
            let actual = try RecordingFinalizer.inspectVideo(url)
            XCTAssertEqual(actual.frames.map(\.pts), source.frames.map(\.pts))
            XCTAssertEqual(actual.codecFourCC, source.codecFourCC)
            for atom in originalAtoms where atom.type == "mdat" {
                XCTAssertEqual(Data(original[atom.offset..<(atom.offset + atom.size)]), Data(output[atom.offset..<(atom.offset + atom.size)]))
            }
            XCTAssertEqual(atoms.filter { $0.type == "moov" }.count, 1)
            XCTAssertTrue(output.range(of: Data(kind.utf8)) != nil)
        }
    }

    func testInvalidAppendRetainsOriginal() throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "writer3frames", withExtension: "mov"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).mov")
        try FileManager.default.copyItem(at: fixture, to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try MOVTelemetryMuxer.append(to: url, kind: "gyrf", packets: [Data([0])], durations: [0], note: Data()))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertThrowsError(try MOVTelemetryMuxer.atoms(Data([0, 0, 0, 9, 109, 111, 111, 118])))
    }

    func testProtobufOfficialWireTypesAndUnits() throws {
        // Official schema: timestamp double/wire 1; gyro and accel float/wire 5.
        XCTAssertEqual(ProtoWire.double(1, 1), Data([9, 0, 0, 0, 0, 0, 0, 240, 63]))
        XCTAssertEqual(ProtoWire.float(2, 1), Data([21, 0, 0, 128, 63]))
        let evidence = CaptureFrameEvidence(sourcePTSSeconds: 0,
            cameraIntrinsicMatrix: [100, 0, 50, 0, 100, 50, 0, 0, 1], intrinsicSource: "test",
            activeVideoStabilizationMode: 0, deviceExposureDurationAtCallbackSeconds: 0.01, deviceISOAtCallback: 100)
        let packet = try EmbeddedTelemetryExporter.protobufPacket(index: 0, pts: 0, evidence: evidence,
            samples: [.init(time: 0, gyro: [.pi / 180, 0, 0], accel: [0, 0, 9.80665])], header: nil)
        XCTAssertTrue(packet.range(of: Data("GyroflowProtobuf".utf8)) != nil)
        XCTAssertTrue(packet.range(of: ProtoWire.float(2, 1)) != nil)
        let bad = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [.nan, 0, 0], accel: [0, 0, 0])
        XCTAssertThrowsError(try EmbeddedTelemetryExporter.protobufPacket(index: 0, pts: 0, evidence: evidence, samples: [bad], header: nil))
    }

    func testExportedAccelerationNegatesAllAxesInBothFormats() throws {
        let sample = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [.pi / 180, 0, 0],
            accel: [0.980665, 1.96133, 2.941995])
        let matrix: [Double] = [100, 0, 50, 0, 100, 50, 0, 0, 1]
        let sony = try EmbeddedTelemetryExporter.sonyPacket(sample, matrix: matrix, width: 1920, height: 1080)
        let range = try XCTUnwrap(sony.range(of: Data([0xe4, 0x4b, 0, 14])))
        let vectorStart = range.upperBound + 8
        let signed = (0..<3).map { Int16(bitPattern: UInt16(sony.uint(vectorStart + $0 * 2, 2))) }
        XCTAssertEqual(signed, [-100, -200, -300]) // Sony units: g, scale 1000.
        let evidence = CaptureFrameEvidence(sourcePTSSeconds: 0, cameraIntrinsicMatrix: matrix,
            intrinsicSource: "test", activeVideoStabilizationMode: 0,
            deviceExposureDurationAtCallbackSeconds: 0.01)
        let proto = try EmbeddedTelemetryExporter.protobufPacket(index: 0, pts: 0, evidence: evidence,
            samples: [sample], header: nil)
        for (index, value) in sample.accel.enumerated() {
            XCTAssertNotNil(proto.range(of: ProtoWire.float(index + 5, Float(-value))))
        }
        XCTAssertNotNil(proto.range(of: ProtoWire.float(2, 1))) // Gyro sign unchanged.
        XCTAssertEqual(sample.accel, [0.980665, 1.96133, 2.941995]) // Source values unchanged.
    }

    func testSonyRejectsUnrepresentableMotionInsteadOfClamping() throws {
        let good = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [0.1, 0, 0], accel: [0, 0, 9.80665])
        let matrix: [Double] = [100, 0, 50, 0, 100, 50, 0, 0, 1]
        let packet = try EmbeddedTelemetryExporter.sonyPacket(good, matrix: matrix, width: 1920, height: 1080)
        XCTAssertEqual(Array(packet.prefix(2)), [0, 28])
        XCTAssertTrue(packet.range(of: Data([0xe4, 0x3b, 0, 14])) != nil)
        let bad = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [1000, 0, 0], accel: good.accel)
        XCTAssertThrowsError(try EmbeddedTelemetryExporter.sonyPacket(bad, matrix: matrix, width: 1920, height: 1080))
    }
}
