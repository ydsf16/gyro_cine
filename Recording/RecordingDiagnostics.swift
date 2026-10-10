import Foundation

struct RecordingDiagnostics: Codable {
    let deviceModel: String
    let systemVersion: String
    let configuredCodec: String
    let audioEnabled: Bool
    let requestedVideo: String
    let submittedFrameCount: Int
    let motionEventCount: Int
    let clock: ClockEvidence?
    var captureError: String?
    var status: String
    var actualCodecFourCC: String? = nil
    var actualWidth: Int? = nil
    var actualHeight: Int? = nil
    var actualFrameCount: Int? = nil
    var actualDurationSeconds: Double? = nil
    var measuredFrameRate: Double? = nil
    var firstVideoPTSSeconds: Double? = nil
    var lastVideoPTSSeconds: Double? = nil
    var gyroStats: MotionRateStats? = nil
    var accelStats: MotionRateStats? = nil
    var actualAudioTrackPresent: Bool? = nil
}

struct MotionRateStats: Codable {
    let count: Int
    let medianHz: Double?
    let p95IntervalMs: Double?
    let maximumGapMs: Double?
    let duplicateTimestampCount: Int

    static func events(_ events: [MotionEvent], kind: MotionEvent.Kind) -> MotionRateStats {
        let times = events.filter { $0.kind == kind }.map(\.timestamp)
        let deltas = zip(times, times.dropFirst()).map { $1 - $0 }.sorted()
        let median = deltas.isEmpty ? nil : deltas[deltas.count / 2]
        let p95 = deltas.isEmpty ? nil : deltas[min(deltas.count - 1, Int(Double(deltas.count) * 0.95))]
        return MotionRateStats(count: times.count,
                               medianHz: median.flatMap { $0 > 0 ? 1 / $0 : nil },
                               p95IntervalMs: p95.map { $0 * 1000 },
                               maximumGapMs: deltas.last.map { $0 * 1000 },
                               duplicateTimestampCount: deltas.filter { $0 == 0 }.count)
    }
}
