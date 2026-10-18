import XCTest
@testable import GyroCine

final class ExposureTimingTests: XCTestCase {
    private let matrix: [Double] = [2000, 0, 1920, 0, 2000, 1080, 0, 0, 1]

    private func tags(_ packet: Data) -> [UInt64: Data] {
        var result: [UInt64: Data] = [:]
        var cursor = 28
        while cursor + 4 <= packet.count {
            let id = packet.uint(cursor, 2), count = Int(packet.uint(cursor + 2, 2))
            cursor += 4
            result[id] = packet.subdata(in: cursor..<(cursor + count))
            cursor += count
        }
        return result
    }

    private func signedMicros(_ data: Data) -> Double {
        Double(Int32(bitPattern: UInt32(data.uint(0, 4)))) / 1e6
    }

    func testSonyConsumerGetsOneExposureOffsetAndAllVectorsPerFrame() throws {
        let samples = [0.003, 0.013].map {
            EmbeddedTelemetryExporter.Sample(time: $0, gyro: [1, 2, 3], accel: [0, 0, 9.80665])
        }
        for model in [ExposureTimingModel.presentationMidpoint, .estimatedReadoutEnd] {
            let packet = try EmbeddedTelemetryExporter.sonyPacket(samples, matrix: matrix, width: 3840, height: 2160,
                timing: .init(exposure: 1.0 / 60, firstRowLatchOffset: model.firstRowLatchOffset(exposure: 1.0 / 60), firstIMUOffset: 0.003))
            let values = tags(packet)
            XCTAssertEqual(values[0xe43b]?.uint(0, 4), 2)
            XCTAssertEqual(values[0xe44b]?.uint(0, 4), 2)
            XCTAssertEqual(values[0xe43b]?.count, 20)
            XCTAssertEqual(values[0xe436]?.uint(0, 4), 1_000_000)
            let offset = signedMicros(try XCTUnwrap(values[0xe437]))
            // Gyroflow stable's Sony consumer adds this offset to video PTS.
            let phase = offset.truncatingRemainder(dividingBy: 0.01)
            let derivedCenter = signedMicros(try XCTUnwrap(values[0xe40c]))
                - signedMicros(try XCTUnwrap(values[0xe40d])) / 2
                + signedMicros(try XCTUnwrap(values[0xe40e])) / 2 + phase - offset
            XCTAssertEqual(derivedCenter, model == .estimatedReadoutEnd ? -1.0 / 120 : 0, accuracy: 0.000001)
        }
    }

    func test120FPSFrameCanCarryExposureWithoutInventingIMUSample() throws {
        let packet = try EmbeddedTelemetryExporter.sonyPacket([], matrix: matrix, width: 3840, height: 2160,
            timing: .init(exposure: 1.0 / 240, firstRowLatchOffset: 0, firstIMUOffset: 0))
        let values = tags(packet)
        XCTAssertEqual(values[0xe43b]?.uint(0, 4), 0)
        XCTAssertEqual(values[0xe44b]?.uint(0, 4), 0)
        XCTAssertEqual(values[0xe43b]?.count, 8)
        XCTAssertEqual(signedMicros(try XCTUnwrap(values[0xe40d])), 1.0 / 240, accuracy: 0.000001)
    }

    private func protoFields(_ data: Data) throws -> [Int: Data] {
        var cursor = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard cursor < data.count else { throw MOVTelemetryMuxer.invalid() }
                let byte = data[cursor]; cursor += 1
                value |= UInt64(byte & 127) << shift
                if byte & 128 == 0 { return value }
            }
            throw MOVTelemetryMuxer.invalid()
        }
        var result: [Int: Data] = [:]
        while cursor < data.count {
            let key = try varint(), field = Int(key >> 3)
            let size: Int
            switch key & 7 {
            case 0: _ = try varint(); continue
            case 1: size = 8
            case 2: size = Int(try varint())
            case 5: size = 4
            default: throw MOVTelemetryMuxer.invalid()
            }
            guard size >= 0, size <= data.count - cursor else { throw MOVTelemetryMuxer.invalid() }
            result[field] = data.subdata(in: cursor..<(cursor + size)); cursor += size
        }
        return result
    }

    private func protoDouble(_ data: Data) throws -> Double {
        guard data.count == 8 else { throw MOVTelemetryMuxer.invalid() }
        let bits = data.enumerated().reduce(UInt64(0)) { $0 | UInt64($1.element) << ($1.offset * 8) }
        return Double(bitPattern: bits)
    }

    func testNewRecordingsUseSameExposureModelInEveryBuild() {
        XCTAssertEqual(ExposureTimingModel.recordingModel, .estimatedReadoutEnd)
    }

    func testSonyAndProtoRetainDynamicExposureAcrossFrameRatesAndDimensions() throws {
        for fps in [24.0, 25, 29.97, 30, 50, 59.94, 60, 120] {
            for (width, height) in [(1920, 1080), (3840, 2160), (4224, 2240), (4224, 3024)] {
                for (index, exposure) in [1 / fps, 1 / (fps * 2), 1.0 / 2000].enumerated() {
                    let pts = Double(index) / fps
                    let sony = tags(try EmbeddedTelemetryExporter.sonyPacket([], matrix: matrix, width: width, height: height,
                        timing: .init(exposure: exposure,
                            firstRowLatchOffset: ExposureTimingModel.recordingModel.firstRowLatchOffset(exposure: exposure),
                            firstIMUOffset: 0)))
                    XCTAssertEqual(signedMicros(try XCTUnwrap(sony[0xe40c])), 0)
                    XCTAssertEqual(signedMicros(try XCTUnwrap(sony[0xe40d])), exposure, accuracy: 0.000001)
                    let evidence = CaptureFrameEvidence(sourcePTSSeconds: pts, cameraIntrinsicMatrix: matrix,
                        intrinsicSource: "test", activeVideoStabilizationMode: 0,
                        deviceExposureDurationAtCallbackSeconds: exposure)
                    let packet = try EmbeddedTelemetryExporter.protobufPacket(index: index, pts: pts,
                        evidence: evidence, samples: [], header: nil)
                    let main = try protoFields(packet)
                    let frame = try protoFields(XCTUnwrap(main[4]))
                    let firstLatch = try protoDouble(XCTUnwrap(frame[1])) / 1e6
                    let lastLatch = try protoDouble(XCTUnwrap(frame[2])) / 1e6
                    let decodedExposure = try protoDouble(XCTUnwrap(frame[5])) / 1e6
                    XCTAssertEqual(decodedExposure, exposure, accuracy: 1e-12)
                    XCTAssertEqual((firstLatch + lastLatch) / 2 - decodedExposure / 2,
                        pts - exposure / 2, accuracy: 1e-12)
                }
            }
        }
    }

    func testRecoveryPreservesChosenExperimentAndAcceptsOlderJobs() throws {
        var job = PendingIMUJob(movieName: "clip.mov", imuName: "clip.imu_raw.jsonl", framesName: "clip.camera_frames.jsonl",
            firstHost: 100, orientation: .landscapeRight, camera: "test", lens: "wide", mode: "SonyMov", retainDebug: true)
        job.exposureTimingModel = .estimatedReadoutEnd
        let encoded = try JSONEncoder().encode(job)
        XCTAssertEqual(try JSONDecoder().decode(PendingIMUJob.self, from: encoded).exposureTimingModel, .estimatedReadoutEnd)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        old.removeValue(forKey: "exposureTimingModel")
        let recovered = try JSONDecoder().decode(PendingIMUJob.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertEqual(recovered.exposureTimingModel ?? .presentationMidpoint, .presentationMidpoint)
    }
}
