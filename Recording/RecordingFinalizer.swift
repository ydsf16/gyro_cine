import AVFoundation
import Foundation

struct ActualVideoFrame { let pts: Double }
struct ActualVideoInfo {
    let frames: [ActualVideoFrame]
    let width: Int
    let height: Int
    let duration: Double
    let codecFourCC: String
}

enum RecordingFinalizer {
    static func inspectVideo(_ url: URL) throws -> ActualVideoInfo {
        try MOVTelemetryMuxer.recoverIfNeeded(url)
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first else {
            throw RecorderError.unavailable("Final MOV has no video track")
        }
        let framesFromIndex: [ActualVideoFrame]
        if let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            var indexed: [ActualVideoFrame] = []
            repeat {
                let pts = cursor.presentationTimeStamp.seconds
                guard pts.isFinite else { throw RecorderError.unavailable("Non-finite indexed video PTS") }
                indexed.append(ActualVideoFrame(pts: pts))
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
            guard !indexed.isEmpty else { throw RecorderError.unavailable("MOV has no indexed video frames") }
            framesFromIndex = indexed
        } else {
            // Compatibility fallback for assets that cannot provide sample cursors.
            framesFromIndex = try readFrames(asset: asset, track: track)
        }
        var frames = framesFromIndex
        frames.sort { $0.pts < $1.pts }
        let description = format as! CMFormatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes = (0..<4).map { Character(UnicodeScalar(UInt8((subtype >> (24 - 8 * $0)) & 0xFF))) }
        return ActualVideoInfo(frames: frames, width: Int(dimensions.width), height: Int(dimensions.height),
                               duration: CMTimeGetSeconds(asset.duration), codecFourCC: String(bytes))
    }

    static func readFrames(asset: AVAsset, track: AVAssetTrack) throws -> [ActualVideoFrame] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw RecorderError.unavailable("Cannot inspect MOV frames") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.unavailable("MOV reader failed") }
        var frames: [ActualVideoFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            // AVAssetReader also emits zero-sample edit/control buffers, including invalid PTS.
            // They are not encoded video frames.
            for index in 0..<CMSampleBufferGetNumSamples(sample) {
                var timing = CMSampleTimingInfo()
                guard CMSampleBufferGetSampleTimingInfo(sample, at: index, timingInfoOut: &timing) == noErr else {
                    throw RecorderError.unavailable("Cannot read encoded sample timing")
                }
                let pts = CMTimeGetSeconds(timing.presentationTimeStamp)
                guard pts.isFinite else { throw RecorderError.unavailable("Non-finite encoded video PTS") }
                frames.append(ActualVideoFrame(pts: pts))
            }
        }
        guard reader.status == .completed, !frames.isEmpty else {
            throw reader.error ?? RecorderError.unavailable("MOV has no readable video frames")
        }
        return frames.sorted { $0.pts < $1.pts }
    }

    static func readMotion(_ url: URL) throws -> [MotionEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(MotionEvent.self, from: Data($0.utf8)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func finalize(folder: URL, clock: ClockEvidence?, outputMode: RecordingOutputMode = .gcsv,
                         retainDebugFiles: Bool = false) throws {
        guard let clock, abs(clock.callbackMinusPTSSeconds) < 2.0 else {
            throw RecorderError.unavailable("Video PTS and host uptime could not be reconciled; raw files retained")
        }
        let started = ProcessInfo.processInfo.systemUptime
        var stage = "inspect MOV sample index"
        defer {
            if stage != "completed" { DiagnosticsCollector.record(String(format: "finalizer stage=%@ elapsed=%.3fs", stage,
                ProcessInfo.processInfo.systemUptime - started), folder: folder) }
        }
        let video = try inspectVideo(folder.recordingFile("mov"))
        DiagnosticsCollector.record(String(format: "MOV index inspected frames=%d elapsed=%.3fs", video.frames.count,
            ProcessInfo.processInfo.systemUptime - started), folder: folder)
        stage = "validate timing and motion"
        let events = try readMotion(folder.appendingPathComponent("imu_raw.jsonl"))
        guard events.contains(where: { $0.kind == .gyro }), events.contains(where: { $0.kind == .accel }) else {
            throw RecorderError.unavailable("Missing gyro or accelerometer samples")
        }
        let diagnosticsURL = folder.appendingPathComponent("diagnostics.json")
        var diagnostics = try JSONDecoder().decode(RecordingDiagnostics.self, from: Data(contentsOf: diagnosticsURL))
        diagnostics.outputMode = outputMode
        if let expected = diagnostics.recordingRotationDegrees {
            let track = AVURLAsset(url: folder.recordingFile("mov")).tracks(withMediaType: .video).first
            guard let transform = track?.preferredTransform else { throw RecorderError.unavailable("Missing video orientation") }
            let actual = (Int((atan2(transform.b, transform.a) * 180 / .pi).rounded()) + 360) % 360
            guard actual == expected,
                  let orientation = RecordingOrientation(rawValue: expected),
                  orientation.matchesMovieTransform(transform, width: video.width, height: video.height) else { throw RecorderError.unavailable("MOV orientation \(actual) differs from captured \(expected)") }
        }
        try JSONEncoder.pretty.encode(diagnostics).write(to: diagnosticsURL)
        let requestedFPS = Double(diagnostics.requestedFrameRate ?? 30)
        let fps = video.frames.count > 1 ? Double(video.frames.count - 1) / (video.frames.last!.pts - video.frames.first!.pts) : 30
        guard fps.isFinite, fps > 0 else { throw RecorderError.unavailable("Invalid measured frame rate") }
        let frameIntervals = zip(video.frames, video.frames.dropFirst()).map { $1.pts - $0.pts }
        guard frameIntervals.allSatisfy({ abs($0 - 1.0 / requestedFPS) <= 0.005 }) else {
            let medianInterval = frameIntervals.sorted()[frameIntervals.count / 2]
            let observedFPS = medianInterval > 0 ? 1 / medianInterval : 0
            let maximumGapMs = (frameIntervals.max() ?? 0) * 1000
            throw RecorderError.unavailable(String(format:
                "视频帧时间异常：目标%.0ffps，实际约%.1ffps，最大帧间隔%.1fms。视频和原始IMU已保留，Gyroflow导出暂停。",
                requestedFPS, observedFPS, maximumGapMs))
        }
        let expectedCodec: String = ["ProRes RAW HQ": "aprh", "ProRes RAW": "aprn",
                                     "ProRes 422 HQ": "apch", "ProRes 422": "apcn",
                                     "H.264": "avc1"].first(where: { $0.key == diagnostics.configuredCodec })?.value ?? "hvc1"
        guard video.codecFourCC == expectedCodec || (expectedCodec == "hvc1" && video.codecFourCC == "hev1") else {
            throw RecorderError.unavailable("Actual codec \(video.codecFourCC) differs from requested \(expectedCodec)")
        }
        let hasAudio = !AVURLAsset(url: folder.recordingFile("mov")).tracks(withMediaType: .audio).isEmpty
        guard !diagnostics.audioEnabled || hasAudio else {
            throw RecorderError.unavailable("Audio was enabled but final MOV has no audio track")
        }
        diagnostics.actualCodecFourCC = video.codecFourCC
        diagnostics.actualWidth = video.width
        diagnostics.actualHeight = video.height
        diagnostics.actualFrameCount = video.frames.count
        diagnostics.actualDurationSeconds = video.duration
        diagnostics.measuredFrameRate = fps
        diagnostics.firstVideoPTSSeconds = video.frames.first?.pts
        diagnostics.lastVideoPTSSeconds = video.frames.last?.pts
        diagnostics.gyroStats = MotionRateStats.events(events, kind: .gyro)
        diagnostics.accelStats = MotionRateStats.events(events, kind: .accel)
        diagnostics.actualAudioTrackPresent = hasAudio
        let evidenceURL = folder.appendingPathComponent("video_samples.jsonl")
        var evidence: [CaptureFrameEvidence] = []
        if FileManager.default.fileExists(atPath: evidenceURL.path) {
            let text = try String(contentsOf: evidenceURL, encoding: .utf8)
            evidence = try text.split(whereSeparator: \.isNewline).map {
                try JSONDecoder().decode(CaptureFrameEvidence.self, from: Data($0.utf8))
            }.sorted { $0.sourcePTSSeconds < $1.sourcePTSSeconds }
            let movieIndexDerived = evidence.first?.evidenceSource == "movie_index_derived"
            guard evidence.count == video.frames.count else {
                throw RecorderError.unavailable("Source timing count differs from actual MOV frame count")
            }
            let residuals = zip(evidence, video.frames).map {
                abs($0.sourcePTSSeconds - clock.firstVideoPTSSeconds + video.frames[0].pts - $1.pts)
            }
            guard residuals.allSatisfy({ $0 <= 0.001 }) else {
                throw RecorderError.unavailable("Source sample PTS and MOV frame mapping differ by more than 1ms")
            }
            if !movieIndexDerived, let hostOrigin = clock.firstVideoHostPTSSeconds {
                let hostTimes = evidence.compactMap(\.hostPTSSeconds)
                guard hostTimes.count == evidence.count else { throw RecorderError.unavailable("Missing converted frame timestamps") }
                let drift = zip(hostTimes, evidence).map {
                    abs(($0 - hostOrigin) - ($1.sourcePTSSeconds - clock.firstVideoPTSSeconds))
                }.max() ?? 0
                diagnostics.recordedClockMap = try RecordedClockMap(host: hostTimes, video: video.frames.map(\.pts))
                diagnostics.maximumCaptureToHostClockDriftMs = drift * 1000
            }
            diagnostics.sourceVideoSampleCount = evidence.count
            diagnostics.framesWithAPIIntrinsics = evidence.filter {
                $0.cameraIntrinsicMatrix != nil && $0.evidenceSource != "movie_index_derived"
            }.count
            if !movieIndexDerived {
                diagnostics.maximumSourceToAssetTimingResidualMs = (residuals.max() ?? 0) * 1000
            }
            let exposures = evidence.compactMap(\.deviceExposureDurationAtCallbackSeconds)
                .filter { $0.isFinite && $0 > 0 }.sorted()
            if !exposures.isEmpty {
                diagnostics.medianDeviceExposureDurationAtCallbackSeconds = exposures[exposures.count / 2]
                diagnostics.minimumDeviceExposureDurationAtCallbackSeconds = exposures.first
                diagnostics.maximumDeviceExposureDurationAtCallbackSeconds = exposures.last
            }
            let isos = evidence.compactMap(\.deviceISOAtCallback).map(Double.init)
                .filter { $0.isFinite && $0 > 0 }.sorted()
            if !isos.isEmpty { diagnostics.medianDeviceISOAtCallback = isos[isos.count / 2] }
        }
        stage = "write Gyroflow sidecars"
        diagnostics.gcsvAlignment = try LegacyGyroflowExporter.write(folder: folder, video: video, events: events,
                                         sourceFirstPTS: clock.firstVideoHostPTSSeconds ?? clock.firstVideoPTSSeconds, fps: fps, evidence: evidence, lens: diagnostics.selectedLens, cameraModel: diagnostics.deviceModel, clockMap: diagnostics.recordedClockMap,
                                         rotationDegrees: diagnostics.recordingRotationDegrees ?? 0)
        diagnostics.outputMode = outputMode
        if outputMode != .gcsv {
            stage = "append embedded metadata"
            try EmbeddedTelemetryExporter.write(mode: outputMode, folder: folder, video: video,
                events: events, evidence: evidence, diagnostics: diagnostics,
                sourceFirstPTS: clock.firstVideoHostPTSSeconds ?? clock.firstVideoPTSSeconds, fps: fps)
            diagnostics.embeddedTelemetryStatus = "embedded; optical sync and RAW color export unverified"
            // Remove legacy delivery sidecars only after a verified metadata append.
            for filename in [folder.recordingFile("gcsv").lastPathComponent, folder.recordingFile("gyroflow").lastPathComponent, "lens_profile.json"] {
                try FileManager.default.removeItem(at: folder.appendingPathComponent(filename))
            }
        }
        stage = "cleanup delivery files"
        diagnostics.status = "completed_unverified_on_device"
        try JSONEncoder.pretty.encode(diagnostics).write(to: diagnosticsURL)
        DiagnosticsCollector.record(String(format: "finalizer export completed elapsed=%.3fs",
            ProcessInfo.processInfo.systemUptime - started), folder: folder)
        if outputMode != .gcsv && !retainDebugFiles {
            for name in ["imu_raw.jsonl", "video_samples.jsonl", "diagnostics.json", "events.log", "embedded_metadata.json"] {
                let item = folder.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: item.path) { try FileManager.default.removeItem(at: item) }
            }
        }
        stage = "completed"
    }
}
