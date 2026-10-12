import AVFoundation
import Foundation

/// Device readbacks gathered alongside MovieFileOutput. They are sampled state,
/// not attachments from the encoded video frames.
struct MovieSensorSample {
    let hostSeconds: Double
    let exposureSeconds: Double
    let iso: Float
    let focusMode: Int
    let lensPosition: Float
    let adjustingFocus: Bool
}

struct MovieFileCaptureContext {
    let firstBufferPTSSeconds: Double
    let firstBufferHostSeconds: Double
    let startCallbackHostSeconds: Double
    let horizontalFieldOfViewDegrees: Float
    let sensorSamples: [MovieSensorSample]
    let stabilizationMode: Int
}

enum MovieFileEvidenceBuilder {
    static func make(video: ActualVideoInfo, context: MovieFileCaptureContext) throws -> (ClockEvidence, [CaptureFrameEvidence]) {
        guard let first = video.frames.first,
              context.firstBufferPTSSeconds.isFinite,
              context.firstBufferHostSeconds.isFinite,
              context.startCallbackHostSeconds.isFinite,
              context.horizontalFieldOfViewDegrees.isFinite,
              context.horizontalFieldOfViewDegrees > 0,
              context.horizontalFieldOfViewDegrees < 179,
              video.width > 0, video.height > 0 else {
            throw RecorderError.unavailable("MOV 时间或镜头视角不可用；原片与 IMU 已保留")
        }
        let samples = context.sensorSamples.filter {
            $0.hostSeconds.isFinite && $0.exposureSeconds.isFinite && $0.exposureSeconds > 0 && $0.iso.isFinite
        }.sorted { $0.hostSeconds < $1.hostSeconds }
        guard !samples.isEmpty else { throw RecorderError.unavailable("没有有效的录制期曝光读数；原片与 IMU 已保留") }

        // The movie connection writes a track matrix, leaving encoded pixels in
        // sensor-native coordinates. This pinhole K uses the format's horizontal
        // field of view and assumes a centered principal point / square pixels.
        let fovRadians = Double(context.horizontalFieldOfViewDegrees) * .pi / 180
        let focalPixels = Double(video.width) / (2 * tan(fovRadians / 2))
        guard focalPixels.isFinite && focalPixels > 0 else {
            throw RecorderError.unavailable("无法估算镜头内参；原片与 IMU 已保留")
        }
        let intrinsic = [focalPixels, 0, Double(video.width) / 2,
                         0, focalPixels, Double(video.height) / 2,
                         0, 0, 1]
        let firstVideoHost = context.firstBufferHostSeconds + first.pts
        let callbackMinusVideo = context.startCallbackHostSeconds - firstVideoHost
        let clock = ClockEvidence(firstVideoHostPTSSeconds: firstVideoHost,
            firstVideoPTSSeconds: context.firstBufferPTSSeconds + first.pts,
            hostClockAtFirstCallbackSeconds: context.startCallbackHostSeconds,
            callbackMinusPTSSeconds: callbackMinusVideo,
            method: "AVCaptureMovieFileOutput didStartRecording startPTS converted through AVCaptureSession.synchronizationClock; MOV sample PTS mapped from the first written buffer. Per-frame host times are derived, not callback measurements.",
            hardwareReadoutTimeKnown: false)
        var sampleIndex = 0
        let evidence = video.frames.map { frame -> CaptureFrameEvidence in
            let host = context.firstBufferHostSeconds + frame.pts
            while sampleIndex + 1 < samples.count && samples[sampleIndex + 1].hostSeconds <= host {
                sampleIndex += 1
            }
            let sample = samples[sampleIndex]
            return CaptureFrameEvidence(hostPTSSeconds: host,
                sourcePTSSeconds: context.firstBufferPTSSeconds + frame.pts,
                cameraIntrinsicMatrix: intrinsic,
                intrinsicSource: "format_horizontal_fov_estimate; centered principal point; distortion uncalibrated",
                activeVideoStabilizationMode: context.stabilizationMode,
                deviceExposureDurationAtCallbackSeconds: sample.exposureSeconds,
                deviceISOAtCallback: sample.iso,
                deviceFocusModeAtCallback: sample.focusMode,
                deviceLensPositionAtCallback: sample.lensPosition,
                deviceIsAdjustingFocusAtCallback: sample.adjustingFocus,
                evidenceSource: "movie_index_derived",
                exposureSource: "nearest_prior_device_poll")
        }
        return (clock, evidence)
    }

    static func write(_ evidence: [CaptureFrameEvidence], to url: URL) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for frame in evidence { data += try encoder.encode(frame) + Data([0x0A]) }
        try data.write(to: url, options: .atomic)
    }
}
