import Foundation

/// Gyroflow 1.6.3 bundle. GCSV starts exactly at the first video frame after boundary interpolation.
enum LegacyGyroflowExporter {
    static func write(folder: URL, video: ActualVideoInfo, events: [MotionEvent],
                      sourceFirstPTS: Double, fps: Double, evidence: [CaptureFrameEvidence], lens: CameraLens? = nil, cameraModel: String = "iPhone", clockMap: RecordedClockMap? = nil, rotationDegrees: Int = 0) throws -> GCSVAlignmentDiagnostics {
        guard sourceFirstPTS.isFinite, fps.isFinite, fps > 0,
              let first = video.frames.first, let finalFrame = video.frames.last else {
            throw RecorderError.unavailable("Invalid video timeline")
        }
        let matrices = evidence.compactMap(\.cameraIntrinsicMatrix)
        guard matrices.count == video.frames.count, matrices.allSatisfy({
            $0.count == 9 && $0.allSatisfy(\.isFinite) && $0[0] > 0 && $0[4] > 0
        }) else { throw RecorderError.unavailable("Fixed lens export requires camera intrinsics on every frame; raw files retained") }
        let k = (0..<9).map { column -> Double in
            let values = matrices.map { $0[column] }.sorted()
            return (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
        }
        let estimatedIntrinsics = evidence.contains { $0.evidenceSource == "movie_index_derived" }
        let codecLabel = ["aprn": "ProRes RAW", "aprh": "ProRes RAW HQ", "apcn": "ProRes 422", "apch": "ProRes 422 HQ", "avc1": "H.264"][video.codecFourCC] ?? "HEVC"
        let profile: [String: Any] = [
            "name": "GyroCine \(lens?.label ?? "fixed lens") \(estimatedIntrinsics ? "format FOV estimate" : "API intrinsics") - distortion UNCALIBRATED",
            "note": estimatedIntrinsics
                ? "Pinhole K estimated from format horizontal FOV; centered principal point and zero distortion are uncalibrated. Optical sync validation required."
                : "Median output-image API K. Zero distortion is an uncalibrated approximation. Offline sync and axis validation required.",
            "camera_brand": "Apple", "camera_model": cameraModel,
            "lens_model": lens.map { "\($0.name) \($0.label) (\($0.deviceType))" } ?? "Unknown physical lens",
            "calibrated_by": estimatedIntrinsics ? "GyroCine format FOV estimate (not calibrated)" : "Apple API intrinsics / GyroCine (not calibrated)",
            "date": String(ISO8601DateFormatter().string(from: Date()).prefix(10)),
            "camera_setting": "\(lens?.name ?? "Unknown lens") \(lens?.label ?? "") \(codecLabel) \(video.width)x\(video.height) \(fps)fps",
            "calibrator_version": estimatedIntrinsics ? "GyroCine-FOV-estimate-v1" : "GyroCine-API-K-unvalidated-v1", "official": false,
            "calib_dimension": ["w": video.width, "h": video.height],
            "orig_dimension": ["w": video.width, "h": video.height], "fps": fps,
            "input_horizontal_stretch": 1.0, "input_vertical_stretch": 1.0,
            "distortion_model": "opencv_standard",
            "fisheye_params": ["camera_matrix": [Array(k[0..<3]), Array(k[3..<6]), Array(k[6..<9])],
                               "distortion_coeffs": Array(repeating: 0.0, count: 8)]
        ]
        // Gyroflow 1.6.3 requires file URLs and relocates missing originals by sibling basename.
        func videoTime(_ timestamp: Double) -> Double {
            clockMap?.videoSeconds(for: timestamp) ?? (timestamp - sourceFirstPTS + first.pts)
        }
        let exposures = evidence.compactMap(\.deviceExposureDurationAtCallbackSeconds)
        guard exposures.count == video.frames.count else {
            throw RecorderError.unavailable("Exposure evidence must cover every encoded frame")
        }
        let exposureTiming = try ExposureTimingCompensation(exposures: exposures)
        let orientation = RecordingOrientation(rawValue: rotationDegrees) ?? .landscapeRight
        let videoEnd = finalFrame.pts + 1.0 / fps
        let aligned = try GyroTimeline.align(events: events, videoStart: first.pts,
                                              videoEnd: videoEnd, map: { exposureTiming.videoTime(forMotionTime: videoTime($0)) })
        let project: [String: Any] = [
            "title": "GyroCine - exposure timing compensated; optical validation pending", "version": 4,
            "videofile": folder.recordingFile("mov").absoluteString, "calibration_data": profile,
            // Let Gyroflow read presentation rotation from MOV; do not override it with zero.
            "video_info": ["width": video.width, "height": video.height,
                           "num_frames": video.frames.count, "fps": fps, "duration_ms": video.duration * 1000],
            "gyro_source": ["filepath": folder.recordingFile("gcsv").absoluteString, "imu_orientation": orientation.imuOrientation, "integration_method": 3],
            "offsets": ["0": 0.0],
            "stabilization": ["frame_readout_time": 0.0, "lens_correction_amount": 1.0,
                              "fov": 1.0, "adaptive_zoom_window": 4.0, "adaptive_zoom_method": 1, "max_zoom": NSNull()],
            "sync": ["do_autosync": false, "initial_offset": 0.0, "search_size": 0.5],
            "output": ["audio": true]
        ]
        var csv = "GYROFLOW IMU LOG\nversion,1.3\nid,GyroCine\norientation,\(orientation.imuOrientation)\nvideofilename,\(folder.recordingFile("mov").lastPathComponent)\nlens_info,\(lens?.label ?? "fixed lens")\nnote,Exposure timing compensated by positive mean half duration; interpolated endpoints; optical sync unverified\ntscale,1\ngscale,1\nt,gx,gy,gz\n"
        for event in aligned.samples {
            csv += [event.time - first.pts, event.x, event.y, event.z]
                .map { String($0) }.joined(separator: ",") + "\n"
        }
        try csv.write(to: folder.recordingFile("gcsv"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: profile, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("lens_profile.json"), options: .atomic)
        try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.recordingFile("gyroflow"), options: .atomic)
        return GCSVAlignmentDiagnostics(sampleCount: aligned.samples.count,
            preRollMs: aligned.preRollSeconds * 1000,
            postRollMs: aligned.postRollSeconds * 1000,
            maximumBoundaryInterpolationGapMs: aligned.maximumBoundaryGapSeconds * 1000,
            videoEndSeconds: videoEnd - first.pts,
            exposureTimingModel: "positive_mean_half_exposure_v1",
            exposureTimingCorrectionMs: exposureTiming.correctionSeconds * 1000,
            minimumExposureTimingCorrectionMs: exposureTiming.minimumHalfExposureSeconds * 1000,
            maximumExposureTimingCorrectionMs: exposureTiming.maximumHalfExposureSeconds * 1000)
    }
}
