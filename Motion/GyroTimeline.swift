import Foundation

struct MappedGyroSample {
    let time: Double
    let x: Double
    let y: Double
    let z: Double
}

struct AlignedGyroTimeline {
    let samples: [MappedGyroSample]
    let preRollSeconds: Double
    let postRollSeconds: Double
    let maximumBoundaryGapSeconds: Double
}

/// Derive a video-bounded GCSV from original motion events. Raw JSONL is never changed.
enum GyroTimeline {
    static let maximumInterpolationGapSeconds = 0.030

    static func align(events: [MotionEvent], videoStart: Double, videoEnd: Double,
                      map: (Double) -> Double) throws -> AlignedGyroTimeline {
        let gyro = events.filter { $0.kind == .gyro }
        guard videoStart.isFinite, videoEnd.isFinite, videoEnd > videoStart,
              gyro.count >= 2, gyro.allSatisfy({ [$0.timestamp, $0.x, $0.y, $0.z].allSatisfy(\.isFinite) }),
              zip(gyro, gyro.dropFirst()).allSatisfy({ $0.timestamp < $1.timestamp }) else {
            throw RecorderError.unavailable("Invalid gyro samples or video interval")
        }
        let mapped = gyro.map { MappedGyroSample(time: map($0.timestamp), x: $0.x, y: $0.y, z: $0.z) }
        guard mapped.allSatisfy({ $0.time.isFinite }),
              zip(mapped, mapped.dropFirst()).allSatisfy({ $0.time < $1.time }),
              mapped[0].time <= videoStart, mapped.last!.time >= videoEnd else {
            throw RecorderError.unavailable("IMU does not cover the complete video interval; raw files retained")
        }

        func boundary(_ time: Double) throws -> (MappedGyroSample, Double) {
            guard let upper = mapped.firstIndex(where: { $0.time >= time }) else {
                throw RecorderError.unavailable("Missing gyro sample after video boundary")
            }
            if mapped[upper].time == time { return (mapped[upper], 0) }
            guard upper > 0 else { throw RecorderError.unavailable("Missing gyro sample before video boundary") }
            let before = mapped[upper - 1], after = mapped[upper]
            let gap = after.time - before.time
            guard gap > 0, gap <= maximumInterpolationGapSeconds else {
                throw RecorderError.unavailable("Gyro gap around video boundary exceeds 30ms; raw files retained")
            }
            let fraction = (time - before.time) / gap
            return (MappedGyroSample(time: time,
                x: before.x + (after.x - before.x) * fraction,
                y: before.y + (after.y - before.y) * fraction,
                z: before.z + (after.z - before.z) * fraction), gap)
        }

        let (first, firstGap) = try boundary(videoStart)
        let (last, lastGap) = try boundary(videoEnd)
        let interior = mapped.filter { $0.time > videoStart && $0.time < videoEnd }
        let output = [first] + interior + [last]
        return AlignedGyroTimeline(samples: output,
            preRollSeconds: videoStart - mapped[0].time,
            postRollSeconds: mapped.last!.time - videoEnd,
            maximumBoundaryGapSeconds: max(firstGap, lastGap))
    }
}
