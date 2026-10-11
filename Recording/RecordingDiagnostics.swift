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
    var outputMode: RecordingOutputMode? = nil
    var recordingRotationDegrees: Int? = nil
    var recordedColorSpace: String? = nil
    var embeddedTelemetryStatus: String? = nil
    var requestedFrameRate: Int? = nil
    var selectedLens: CameraLens? = nil
    var requestedShutter: String? = nil
    var exposureControlMode: String? = nil
    var requestedMaximumExposureDurationSeconds: Double? = nil
    var medianDeviceExposureDurationAtCallbackSeconds: Double? = nil
    var minimumDeviceExposureDurationAtCallbackSeconds: Double? = nil
    var maximumDeviceExposureDurationAtCallbackSeconds: Double? = nil
    var medianDeviceISOAtCallback: Double? = nil
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
    var recordedClockMap: RecordedClockMap? = nil
    var maximumCaptureToHostClockDriftMs: Double? = nil
    var sourceVideoSampleCount: Int? = nil
    var framesWithAPIIntrinsics: Int? = nil
    var maximumSourceToAssetTimingResidualMs: Double? = nil
    var intrinsicCalibrationStatus: String = "API K is optional; lens distortion, readout and OIS remain unknown"
    var actualAudioTrackPresent: Bool? = nil
    var gcsvAlignment: GCSVAlignmentDiagnostics? = nil
}

struct GCSVAlignmentDiagnostics: Codable {
    let sampleCount: Int
    let preRollMs: Double
    let postRollMs: Double
    let maximumBoundaryInterpolationGapMs: Double
    let videoEndSeconds: Double
    var exposureTimingModel: String? = nil
    var exposureTimingCorrectionMs: Double? = nil
    var minimumExposureTimingCorrectionMs: Double? = nil
    var maximumExposureTimingCorrectionMs: Double? = nil
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
