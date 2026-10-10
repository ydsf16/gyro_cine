import Foundation

// These field names and types match the pinned gyroflow.proto. Unknown calibration is omitted.
struct GFMain: Encodable {
    let magicString: String?
    let protocolVersion: Int?
    let header: GFHeader?
    let frame: GFFrame
}
struct GFHeader: Encodable { let camera: GFCamera; let clip: GFClip }
struct GFCamera: Encodable { let cameraBrand: String; let cameraModel: String }
struct GFClip: Encodable {
    let frameWidth: Int
    let frameHeight: Int
    let durationUs: Double
    let fileFrameRate: Double
}
struct GFFrame: Encodable { let frameNumber: Int; let imu: [GFIMU] }
struct GFIMU: Encodable {
    let sampleTimestampUs: Double
    let gyroscopeX: Double
    let gyroscopeY: Double
    let gyroscopeZ: Double
    let accelerometerX: Double
    let accelerometerY: Double
    let accelerometerZ: Double
}

enum GyroflowJSONLWriter {
    static func groupIndices(framePTS: [Double], samplePTS: [Double]) -> [[Int]] {
        guard !framePTS.isEmpty else { return [] }
        var groups = Array(repeating: [Int](), count: framePTS.count)
        for (index, time) in samplePTS.enumerated() {
            var low = 0
            var high = framePTS.count - 1
            while low < high {
                let middle = (low + high) / 2
                let boundary = (framePTS[middle] + framePTS[middle + 1]) / 2
                if time < boundary { high = middle } else { low = middle + 1 }
            }
            groups[low].append(index)
        }
        return groups
    }

    static func write(to url: URL, video: ActualVideoInfo, events: [MotionEvent],
                      sourceVideoFirstPTS: Double, fileFrameRate: Double) throws {
        let firstAssetPTS = video.frames[0].pts
        let relativeTimes = events.map { $0.timestamp - sourceVideoFirstPTS + firstAssetPTS }
        let groups = groupIndices(framePTS: video.frames.map(\.pts), samplePTS: relativeTimes)
        var gyro = events.first { $0.kind == .gyro }!
        var accel = events.first { $0.kind == .accel }!
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = Data()
        for index in video.frames.indices {
            let samples = groups[index].map { eventIndex -> GFIMU in
                let event = events[eventIndex]
                if event.kind == .gyro { gyro = event } else { accel = event }
                return GFIMU(sampleTimestampUs: relativeTimes[eventIndex] * 1_000_000,
                             gyroscopeX: ClockAligner.degreesPerSecond(gyro.x),
                             gyroscopeY: ClockAligner.degreesPerSecond(gyro.y),
                             gyroscopeZ: ClockAligner.degreesPerSecond(gyro.z),
                             accelerometerX: accel.x, accelerometerY: accel.y, accelerometerZ: accel.z)
            }
            let header = index == 0 ? GFHeader(camera: GFCamera(cameraBrand: "Apple", cameraModel: "iPhone"),
                                                clip: GFClip(frameWidth: video.width, frameHeight: video.height,
                                                             durationUs: video.duration * 1_000_000,
                                                             fileFrameRate: fileFrameRate)) : nil
            let message = GFMain(magicString: index == 0 ? "GyroflowProtobuf" : nil,
                                 protocolVersion: index == 0 ? 1 : nil,
                                 header: header, frame: GFFrame(frameNumber: index + 1, imu: samples))
            data.append(try encoder.encode(message))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}
