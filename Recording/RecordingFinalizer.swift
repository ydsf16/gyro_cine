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
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first else {
            throw RecorderError.unavailable("Final MOV has no video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        guard reader.canAdd(output) else { throw RecorderError.unavailable("Cannot inspect MOV frames") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.unavailable("MOV reader failed") }
        var frames: [ActualVideoFrame] = []
        while let sample = output.copyNextSampleBuffer() {
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard pts.isFinite else { throw RecorderError.unavailable("Non-finite video PTS") }
            frames.append(ActualVideoFrame(pts: pts))
        }
        guard reader.status == .completed, !frames.isEmpty else {
            throw reader.error ?? RecorderError.unavailable("MOV has no readable video frames")
        }
        frames.sort { $0.pts < $1.pts }
        let description = format as! CMFormatDescription
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let bytes = (0..<4).map { Character(UnicodeScalar(UInt8((subtype >> (24 - 8 * $0)) & 0xFF))) }
        return ActualVideoInfo(frames: frames, width: Int(dimensions.width), height: Int(dimensions.height),
                               duration: CMTimeGetSeconds(asset.duration), codecFourCC: String(bytes))
    }

    static func readMotion(_ url: URL) throws -> [MotionEvent] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try text.split(whereSeparator: \.isNewline).map { try JSONDecoder().decode(MotionEvent.self, from: Data($0.utf8)) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    static func finalize(folder: URL, clock: ClockEvidence?) throws {
        guard let clock, abs(clock.callbackMinusPTSSeconds) < 2.0 else {
            throw RecorderError.unavailable("Video PTS and host uptime could not be reconciled; raw files retained")
        }
        let video = try inspectVideo(folder.appendingPathComponent("clip.mov"))
        guard video.codecFourCC == "hvc1" || video.codecFourCC == "hev1" else {
            throw RecorderError.unavailable("Actual video codec is \(video.codecFourCC), expected HEVC")
        }
        let events = try readMotion(folder.appendingPathComponent("imu_raw.jsonl"))
        guard events.contains(where: { $0.kind == .gyro }), events.contains(where: { $0.kind == .accel }) else {
            throw RecorderError.unavailable("Missing gyro or accelerometer samples")
        }
        let fps = video.frames.count > 1 ? Double(video.frames.count - 1) / (video.frames.last!.pts - video.frames.first!.pts) : 30
        guard fps.isFinite, fps > 0 else { throw RecorderError.unavailable("Invalid measured frame rate") }
        let frameIntervals = zip(video.frames, video.frames.dropFirst()).map { $1.pts - $0.pts }
        guard frameIntervals.allSatisfy({ abs($0 - 1.0 / 30.0) <= 0.005 }) else {
            throw RecorderError.unavailable("MOV has irregular or dropped frame PTS; constant-rate Gyroflow timeline would be inaccurate. Raw files retained")
        }
        try GyroflowJSONLWriter.write(to: folder.appendingPathComponent("clip.jsonl"), video: video, events: events,
                                      sourceVideoFirstPTS: clock.firstVideoPTSSeconds, fileFrameRate: fps)
        let diagnosticsURL = folder.appendingPathComponent("diagnostics.json")
        var diagnostics = try JSONDecoder().decode(RecordingDiagnostics.self, from: Data(contentsOf: diagnosticsURL))
        let hasAudio = !AVURLAsset(url: folder.appendingPathComponent("clip.mov")).tracks(withMediaType: .audio).isEmpty
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
        diagnostics.status = "completed_unverified_on_device"
        try JSONEncoder.pretty.encode(diagnostics).write(to: diagnosticsURL)
    }
}
