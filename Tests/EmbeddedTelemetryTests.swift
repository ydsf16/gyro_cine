import XCTest
import AVFoundation
@testable import GyroCine

final class EmbeddedTelemetryTests: XCTestCase {
    func testCopyCapacityUsesDestinationFreeBytesWhenImportantUsageIsZero() throws {
        XCTAssertNoThrow(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: 813_038_567_424,
            important: 0, required: 700_000_000))
        XCTAssertThrowsError(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: 100,
            important: 813_038_567_424, required: 700_000_000))
        XCTAssertThrowsError(try MOVTelemetryMuxer.checkCopyCapacity(ordinary: nil,
            important: nil, required: 700_000_000))
    }
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
        let bad = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [.nan, 0, 0], accel: good.accel)
        XCTAssertThrowsError(try EmbeddedTelemetryExporter.sonyPacket(bad, matrix: matrix, width: 1920, height: 1080))
    }

    func testSonyScalePreservesFastMotionWithoutClipping() throws {
        for speed in [1.0, 327.67, 328, 720, 2000, 10000] {
            let sample = EmbeddedTelemetryExporter.Sample(time: 0,
                gyro: [speed, -speed, speed / 3].map { $0 * .pi / 180 }, accel: [400, -400, 0])
            let packet = try EmbeddedTelemetryExporter.sonyPacket(sample,
                matrix: [100, 0, 50, 0, 100, 50, 0, 0, 1], width: 1920, height: 1080)
            for (scaleTag, vectorTag, expected) in [
                (Data([0xe4, 0x39, 0, 4]), Data([0xe4, 0x3b, 0, 14]), [speed, -speed, speed / 3]),
                (Data([0xe4, 0x49, 0, 4]), Data([0xe4, 0x4b, 0, 14]), [-400 / 9.80665, 400 / 9.80665, 0])
            ] {
                let scaleStart = try XCTUnwrap(packet.range(of: scaleTag)).upperBound
                let scale = Double(Float(bitPattern: UInt32(packet.uint(scaleStart, 4))))
                let start = try XCTUnwrap(packet.range(of: vectorTag)).upperBound + 8
                for axis in 0..<3 {
                    let raw = Int16(bitPattern: UInt16(packet.uint(start + axis * 2, 2)))
                    XCTAssertEqual(Double(raw) / scale, expected[axis], accuracy: 0.5001 / scale)
                }
            }
        }
    }

    func testPortraitTelemetryKeepsSensorAxesAndDeclaresDisplayRotation() throws {
        let video = ActualVideoInfo(frames: [ActualVideoFrame(pts: 0)], width: 1920, height: 1080,
                                    duration: 1, codecFourCC: "hvc1")
        let header = EmbeddedTelemetryExporter.protobufHeader(video: video, fps: 30,
            camera: "iPhone", lens: "Wide", profile: Data(), note: Data(), rotationDegrees: 90)
        XCTAssertNotNil(header.range(of: ProtoWire.string(13, "XYZ")))
        XCTAssertNotNil(header.range(of: ProtoWire.integer(7, 90)))
        let sample = EmbeddedTelemetryExporter.Sample(time: 0, gyro: [.pi / 180, 0, 0],
            accel: [0.980665, 1.96133, 2.941995])
        let matrix: [Double] = [100, 0, 50, 0, 100, 50, 0, 0, 1]
        let packet = try EmbeddedTelemetryExporter.sonyPacket(sample, matrix: matrix,
            width: 1920, height: 1080, orientation: .portrait)
        let gyroTag = try XCTUnwrap(packet.range(of: Data([0xe4, 0x3b, 0, 14])))
        let g = (0..<3).map { Int16(bitPattern: UInt16(packet.uint(gyroTag.upperBound + 8 + $0 * 2, 2))) }
        XCTAssertEqual(g, [100, 0, 0])
        let accelTag = try XCTUnwrap(packet.range(of: Data([0xe4, 0x4b, 0, 14])))
        let a = (0..<3).map { Int16(bitPattern: UInt16(packet.uint(accelTag.upperBound + 8 + $0 * 2, 2))) }
        XCTAssertEqual(a, [-100, -200, -300])
    }
}
