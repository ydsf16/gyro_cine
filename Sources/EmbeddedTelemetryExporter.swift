import AVFoundation
import Foundation

struct ActualVideoFrame { let pts: Double }
struct ActualVideoInfo {
    let frames: [ActualVideoFrame]
    let width: Int
    let height: Int
    let duration: Double
    let codecFourCC: String
    var rotationDegrees: Int = 0
}

/// Piecewise-linear correspondence between MOV presentation and real capture
/// time. The final frame's duration extends at unit rate, with no invented frame.
struct VideoCaptureTimeMap {
    let presentation: [Double]
    let capture: [Double]

    func captureTime(at time: Double) -> Double { Self.map(time, from: presentation, to: capture) }
    func presentationTime(at time: Double) -> Double { Self.map(time, from: capture, to: presentation) }

    private static func map(_ time: Double, from: [Double], to: [Double]) -> Double {
        guard let first = from.first, let last = from.last else { return time }
        if time <= first { return to[0] + time - first }
        if time >= last { return to[to.count - 1] + time - last }
        var low = 0, high = from.count - 1
        while low + 1 < high {
            let mid = (low + high) / 2
            if from[mid] <= time { low = mid } else { high = mid }
        }
        return to[low] + (time - from[low]) / (from[high] - from[low]) * (to[high] - to[low])
    }
}

/// A declared export convention, not a hardware timestamp measurement.
enum ExposureTimingModel: String, Codable {
    case presentationMidpoint
    case estimatedReadoutEnd

    // Shared by every codec, lens, frame rate and storage destination.
    // Gyroflow applies the exposure-center adjustment from the metadata once.
    static let recordingModel: Self = .estimatedReadoutEnd

    func firstRowLatchOffset(exposure: Double) -> Double {
        // Readout duration is unknown and modeled as zero. In the baseline
        // convention the derived exposure midpoint remains at the MOV PTS.
        self == .estimatedReadoutEnd ? 0 : exposure / 2
    }
}

enum EmbeddedTelemetryExporter {
    struct Sample { let time: Double; let gyro: [Double]; let accel: [Double] }
    struct SonyTiming {
        let exposure: Double
        let firstRowLatchOffset: Double
        let firstIMUOffset: Double
    }

    static func sonyPacket(_ samples: [Sample], matrix: [Double], width: Int, height: Int,
                           timing: SonyTiming,
                           orientation: RecordingOrientation = .landscapeRight) throws -> Data {
        guard matrix.count == 9, width > 0, height > 0, width * 10 <= UInt16.max, height * 10 <= UInt16.max,
              samples.count <= 10_000, timing.exposure.isFinite, timing.exposure > 0 else { throw MOVTelemetryMuxer.invalid() }
        func tag(_ id: UInt64, _ data: Data) -> Data { Data.be(id, 2) + Data.be(UInt64(data.count), 2) + data }
        func microseconds(_ seconds: Double) throws -> Data {
            let value = (seconds * 1e6).rounded()
            guard value.isFinite, value >= Double(Int32.min), value <= Double(Int32.max) else {
                throw MOVTelemetryMuxer.invalid()
            }
            return Data.be(UInt64(UInt32(bitPattern: Int32(value))), 4)
        }
        // Virtual unit conversion for Sony's lens fallback. Never claim this is measured sensor geometry.
        var p = tag(0xe405, Data.be(UInt64(width), 2) + Data.be(UInt64(height), 2))
        p += tag(0xe407, Data.be(10000, 2) + Data.be(10000, 2))
        p += tag(0xe40a, Data.be(UInt64(width), 4) + Data.be(UInt64(height), 4))
        p += tag(0x8104, Data.be(UInt64(width * 10), 2)) + tag(0x8105, Data.be(UInt64(height * 10), 2))
        let focal = matrix[0] * 10000
        guard focal.isFinite, focal > 0, focal <= Double(UInt32.max) else { throw MOVTelemetryMuxer.invalid() }
        p += tag(0xe421, Data.be(UInt64(focal.rounded()), 4) + Data.be(0, 4) + Data([0]) + Data.be(UInt64(Float(1).bitPattern), 4) + Data.be(0, 4) + Data.be(2, 4))
        p += tag(0xe420, Data([0]))
        p += tag(0xe40c, try microseconds(timing.firstRowLatchOffset))
        p += tag(0xe40d, try microseconds(timing.exposure))
        p += tag(0xe40e, try microseconds(0)) // Unknown readout: explicit zero model, disclosed in rmin.
        for (start, vectors, preferredScale) in [(UInt64(0xe435), samples.map { orientation.remap($0.gyro).map { $0 * 180 / .pi } }, Float(100)),
                                        (UInt64(0xe445), samples.map { orientation.remap($0.accel).map { ClockAligner.exportedAcceleration($0) / 9.80665 } }, Float(1000))] {
            guard vectors.allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isFinite) }) else {
                throw RecorderError.unavailable("Sony 元数据包含无效 IMU 数值；原始记录已保留")
            }
            // RTMD carries a float scale per sample/group. Reduce precision only as
            // needed to preserve peaks instead of clipping valid fast motion.
            let peak = vectors.flatMap { $0 }.map { abs($0) }.max() ?? 0
            var scale = preferredScale
            while peak * Double(scale) > Double(Int16.max) {
                scale /= 2
                guard scale.isFinite, scale > 0 else {
                    throw RecorderError.unavailable("Sony IMU 数值超出可编码范围；原始记录已保留")
                }
            }
            var vector = Data()
            for value in vectors.flatMap({ $0 }) {
                let integer = (value * Double(scale)).rounded()
                guard integer.isFinite, integer >= Double(Int16.min), integer <= Double(Int16.max) else {
                    throw RecorderError.unavailable("Sony metadata range exceeded; original retained")
                }
                vector += Data.be(UInt64(UInt16(bitPattern: Int16(integer))), 2)
            }
            // Gyroflow's Sony parser swaps X/Y and inverts Z during normalization.
            // Encode YXz so its resulting IMU orientation is XYZ, like GCSV.
            p += tag(start, Data.be(100, 4)) + tag(start + 1, Data.be(1_000_000, 4))
                + tag(start + 2, try microseconds(timing.firstIMUOffset))
                + tag(start + 4, Data.be(UInt64(scale.bitPattern), 4))
                + tag(start + 5, Data.be(0x502, 2))
                + tag(start + 6, Data.be(UInt64(samples.count), 4) + Data.be(6, 4) + vector)
        }
        return Data([0, 0x1c]) + Data(repeating: 0, count: 26) + p
    }

    static func protobufHeader(video: ActualVideoInfo, fps: Double, camera: String, lens: String, profile: Data, note: Data, rotationDegrees: Int = 0) -> Data {
        var c = ProtoWire.string(1, "Apple") + ProtoWire.string(2, camera) + ProtoWire.string(5, "Apple")
        let orientation = RecordingOrientation(rawValue: rotationDegrees) ?? .landscapeRight
        c += ProtoWire.string(6, lens) + ProtoWire.bytes(12, profile) + ProtoWire.string(13, orientation.imuOrientation) + ProtoWire.bytes(16, note)
        // Unknown sensor size/pixel pitch/readout fields are omitted, never fabricated.
        var clip = ProtoWire.integer(1, UInt64(video.width)) + ProtoWire.integer(2, UInt64(video.height))
        clip += ProtoWire.double(3, video.duration * 1e6) + ProtoWire.float(4, Float(fps))
            + ProtoWire.float(5, Float(fps)) + ProtoWire.float(6, Float(fps))
            + ProtoWire.integer(7, UInt64(rotationDegrees))
            + ProtoWire.integer(8, 100) + ProtoWire.float(10, 1)
        return ProtoWire.bytes(1, c) + ProtoWire.bytes(2, clip)
    }

    static func protobufPacket(index: Int, pts: Double, evidence: CaptureFrameEvidence, samples: [Sample], header: Data?,
                               timingModel: ExposureTimingModel = .recordingModel) throws -> Data {
        guard let matrix = evidence.cameraIntrinsicMatrix, matrix.count == 9,
              let exposure = evidence.deviceExposureDurationAtCallbackSeconds, exposure.isFinite, exposure > 0,
              matrix.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw MOVTelemetryMuxer.invalid() }
        // Both first/last row latch use the declared zero-readout model.
        // The current model derives midpoint = MOV PTS - exposure/2.
        let latch = (pts + timingModel.firstRowLatchOffset(exposure: exposure)) * 1e6
        var frame = ProtoWire.double(1, latch) + ProtoWire.double(2, latch) + ProtoWire.integer(3, UInt64(index + 1))
            + ProtoWire.double(5, exposure * 1e6)
        if let iso = evidence.deviceISOAtCallback, iso.isFinite, iso > 0, Double(iso) <= Double(UInt32.max) {
            frame += ProtoWire.integer(4, UInt64(iso.rounded()))
        }
        var packed = Data()
        for value in matrix { packed += ProtoWire.little(UInt64(Float(value).bitPattern), 4) }
        frame += ProtoWire.bytes(16, ProtoWire.bytes(1, packed))
        for sample in samples {
            var imu = ProtoWire.double(1, sample.time * 1e6)
            let values = sample.gyro.map { $0 * 180 / .pi } + sample.accel.map(ClockAligner.exportedAcceleration)
            guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw MOVTelemetryMuxer.invalid() }
            for (i, value) in values.enumerated() { imu += ProtoWire.float(i + 2, Float(value)) }
            frame += ProtoWire.bytes(17, imu)
        }
        var main = ProtoWire.string(1, "GyroflowProtobuf") + ProtoWire.integer(2, 1)
        if let header { main += ProtoWire.bytes(3, header) }
        return main + ProtoWire.bytes(4, frame)
    }
}

/// Minimal protobuf wire writer for the pinned official gyroflow.proto fields used above.
/// Field numbers/types are checked against the generated official decoder in acceptance tests.
enum ProtoWire {
    static func varint(_ input: UInt64) -> Data {
        var value = input, data = Data()
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value)); return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func little(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func double(_ field: Int, _ value: Double) -> Data { varint(UInt64(field << 3 | 1)) + little(value.bitPattern, 8) }
    static func float(_ field: Int, _ value: Float) -> Data { varint(UInt64(field << 3 | 5)) + little(UInt64(value.bitPattern), 4) }
}
