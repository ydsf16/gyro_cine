import Foundation

/// Samples file length only; never reads video data or runs on a capture callback.
struct RecordingRateEstimator {
    private struct Observation { let time: Double; let bytes: Int64 }
    private var observations: [Observation] = []
    private(set) var bytesPerSecond: Double?
    private(set) var measuredSeconds: Double = 0

    mutating func observe(bytes: Int64, at time: Double) {
        guard bytes >= 0, time.isFinite else { return }
        if let last = observations.last {
            guard time > last.time else { return }
            if bytes < last.bytes { self = Self() }
        }
        observations.append(.init(time: time, bytes: bytes))
        // Keep an anchor at or just before the rolling window boundary.
        while observations.count > 2, observations[1].time <= time - 12 {
            observations.removeFirst()
        }
        guard let first = observations.first else { return }
        let elapsed = time - first.time
        guard elapsed >= 4 else { return }
        let measured = Double(bytes - first.bytes) / elapsed
        // A delayed container flush must not turn the prediction into infinity.
        // Retain the latest valid rate until file growth resumes.
        guard measured.isFinite, measured >= 100_000 else { return }
        bytesPerSecond = bytesPerSecond.map { $0 * 0.65 + measured * 0.35 } ?? measured
        measuredSeconds = elapsed
    }

    static func displayRate(live: Double?, learned: Double, fallback: Double) -> Double {
        if let live, live.isFinite, live >= 100_000 { return live }
        if learned.isFinite, learned >= 100_000 { return learned }
        return max(100_000, fallback.isFinite ? fallback : 100_000)
    }
}
