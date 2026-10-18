import AVFoundation
import CoreMotion
import Foundation

struct MotionEvent: Codable {
    enum Kind: String, Codable { case gyro, accel }
    let kind: Kind
    let timestamp: Double
    let x: Double
    let y: Double
    let z: Double
}

struct VideoCadenceHealth {
    let maximumGap: Double
    let missingFrames: Int
    let expectedFrames: Int
    let hasInvalidTimestamps: Bool
    var hasHeavyFrameLoss: Bool { missingFrames > max(3, expectedFrames / 20) }
    var isSeverelyDiscontinuous: Bool { maximumGap > 0.1 || hasHeavyFrameLoss }

    init(frames: [ActualVideoFrame], fps: Double) {
        let times = frames.map(\.pts).filter(\.isFinite).sorted()
        hasInvalidTimestamps = times.count != frames.count || Set(times).count != times.count
        let gaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter { $0 > 0 }
        maximumGap = gaps.max() ?? 0
        missingFrames = gaps.reduce(0) { $0 + max(0, Int(($1 * fps).rounded()) - 1) }
        expectedFrames = max(times.count + missingFrames, 1)
    }

    func validate(fps: Double) throws {
        guard !hasInvalidTimestamps else {
            throw RecorderError.unavailable("MOV 含无效或重复帧时间；原始 MOV 与 IMU 已保留")
        }
        // A sparse but valid PTS timeline can still be matched to measured IMU.
        // Keep cadence warnings in metadata; reject sustained loss, not one long interval.
        guard !hasHeavyFrameLoss else {
            throw RecorderError.unavailable(String(format:
                "视频帧时间异常：%.0f fps 最大间隔 %.0f ms，估计缺少 %d 帧；原始 MOV 与 IMU 已保留",
                fps, maximumGap * 1000, missingFrames))
        }
    }
}

/// Captures raw, monotonic CoreMotion samples before and after MovieFileOutput runs.
final class IMURecorder {
    private let manager = CMMotionManager()
    private let samples = OperationQueue()
    private let lock = NSLock()
    private var handle: FileHandle?
    private var firstGyro: Double?
    private var lastGyro: Double?
    private var firstAccel: Double?
    private var failure: String?
    private let encoder = JSONEncoder()
    private(set) var url: URL?

    init() {
        samples.name = "GyroCine.IMU"
        samples.maxConcurrentOperationCount = 1
    }

    var isAvailable: Bool { manager.isGyroAvailable && manager.isAccelerometerAvailable }
    var firstGyroTime: Double? { lock.lock(); defer { lock.unlock() }; return firstGyro }
    var firstAccelTime: Double? { lock.lock(); defer { lock.unlock() }; return firstAccel }
    var lastGyroTime: Double? { lock.lock(); defer { lock.unlock() }; return lastGyro }

    func start(at url: URL) throws {
        guard isAvailable else { throw RecorderError.unavailable("陀螺仪或加速度计不可用") }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        firstGyro = nil; lastGyro = nil; firstAccel = nil; failure = nil
        manager.gyroUpdateInterval = 0.01
        manager.accelerometerUpdateInterval = 0.01
        manager.startGyroUpdates(to: samples) { [weak self] sample, error in
            guard let sample else { self?.setFailure(error); return }
            self?.append(MotionEvent(kind: .gyro, timestamp: sample.timestamp,
                x: sample.rotationRate.x, y: sample.rotationRate.y, z: sample.rotationRate.z))
        }
        manager.startAccelerometerUpdates(to: samples) { [weak self] sample, error in
            guard let sample else { self?.setFailure(error); return }
            self?.append(MotionEvent(kind: .accel, timestamp: sample.timestamp,
                x: sample.acceleration.x * 9.80665, y: sample.acceleration.y * 9.80665,
                z: sample.acceleration.z * 9.80665))
        }
    }

    private func setFailure(_ error: Error?) {
        lock.lock(); failure = error?.localizedDescription ?? "IMU 采集失败"; lock.unlock()
    }

    private func append(_ event: MotionEvent) {
        lock.lock(); defer { lock.unlock() }
        do {
            try handle?.write(contentsOf: encoder.encode(event) + Data([10]))
            if event.kind == .gyro {
                if firstGyro == nil { firstGyro = event.timestamp }
                lastGyro = event.timestamp
            } else if firstAccel == nil { firstAccel = event.timestamp }
        } catch { failure = error.localizedDescription }
    }

    func stop() throws {
        manager.stopGyroUpdates(); manager.stopAccelerometerUpdates()
        samples.waitUntilAllOperationsAreFinished()
        lock.lock(); defer { lock.unlock() }
        try handle?.synchronize(); try handle?.close(); handle = nil
        if let failure { throw RecorderError.unavailable("IMU: \(failure)") }
    }
}

enum MovieIMUFinalizer {
    static let margin = 0.05
    static let maximumGap = 0.03

    static func inspect(_ url: URL) throws -> ActualVideoInfo {
        try MOVTelemetryMuxer.recoverIfNeeded(url)
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first,
              let format = track.formatDescriptions.first else {
            throw RecorderError.unavailable("MOV 没有视频轨")
        }
        var frames: [ActualVideoFrame] = []
        if let cursor = track.makeSampleCursorAtFirstSampleInDecodeOrder() {
            // The sample cursor reads the MOV timing index without loading the
            // compressed video payload. Its PTS matches AVAssetReader's PTS.
            repeat {
                let pts = cursor.presentationTimeStamp.seconds
                guard pts.isFinite else { throw RecorderError.unavailable("MOV 帧时间无效") }
                frames.append(.init(pts: pts))
            } while cursor.stepInDecodeOrder(byCount: 1) == 1
        } else {
            // Keep compatibility with MOV variants that cannot provide cursors.
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? RecorderError.unavailable("无法读取视频帧时间") }
            while let buffer = output.copyNextSampleBuffer() {
                for index in 0..<CMSampleBufferGetNumSamples(buffer) {
                    var timing = CMSampleTimingInfo()
                    guard CMSampleBufferGetSampleTimingInfo(buffer, at: index, timingInfoOut: &timing) == noErr,
                          timing.presentationTimeStamp.seconds.isFinite else {
                        throw RecorderError.unavailable("MOV 帧时间无效")
                    }
                    frames.append(.init(pts: timing.presentationTimeStamp.seconds))
                }
            }
            guard reader.status == .completed else {
                throw reader.error ?? RecorderError.unavailable("无法读取视频帧时间")
            }
        }
        guard frames.count >= 2 else { throw RecorderError.unavailable("MOV 视频帧不足") }
        frames.sort { $0.pts < $1.pts }
        let dims = CMVideoFormatDescriptionGetDimensions(format as! CMVideoFormatDescription)
        let code = CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription)
        let fourCC = String(bytes: (0..<4).map { UInt8((code >> (24 - $0 * 8)) & 255) }, encoding: .ascii) ?? "unknown"
        return ActualVideoInfo(frames: frames, width: Int(dims.width), height: Int(dims.height),
            duration: asset.duration.seconds, codecFourCC: fourCC,
            rotationDegrees: (Int((atan2(track.preferredTransform.b, track.preferredTransform.a) * 180 / .pi).rounded()) + 360) % 360)
    }

    static func finalize(movie: URL, rawIMU: URL, firstFrameHost: Double,
                         cameraFrames: URL, orientation: RecordingOrientation,
                         camera: String, lens: String, mode: String, retainDebug: Bool,
                         expectedFPS: Double? = nil, timingSource: String? = nil,
                         exposureTimingModel: ExposureTimingModel = .recordingModel,
                         progress: ((String, Double) -> Void)? = nil) throws -> (Int, Double, Double) {
        var checkpoint = ProcessInfo.processInfo.systemUptime
        func completed(_ stage: String) {
            let now = ProcessInfo.processInfo.systemUptime
            progress?(stage, now - checkpoint)
            checkpoint = now
        }
        let video = try inspect(movie)
        completed("readVideoFrameTimes")
        if let expectedFPS, expectedFPS.isFinite, expectedFPS > 0,
           video.duration.isFinite, video.duration > 0 {
            let minimumFrames = max(2, Int((video.duration * expectedFPS * 0.8).rounded(.down)))
            guard video.frames.count >= minimumFrames else {
                throw RecorderError.unavailable("MOV 视频帧率严重不足：\(video.frames.count)/\(minimumFrames) 帧；原始文件已保留")
            }
            try VideoCadenceHealth(frames: video.frames, fps: expectedFPS).validate(fps: expectedFPS)
        }
        guard video.rotationDegrees == orientation.degrees else {
            throw RecorderError.unavailable("MOV 方向与录制时重力方向不一致；原始文件已保留")
        }
        let first = video.frames[0].pts
        let intervals = zip(video.frames, video.frames.dropFirst()).map { $1.pts - $0.pts }.filter { $0 > 0 }
        guard !intervals.isEmpty else { throw RecorderError.unavailable("Invalid video frame timestamps") }
        let frameDuration = intervals.sorted()[intervals.count / 2]
        let end = video.frames.last!.pts - first + frameDuration
        guard end > 0, firstFrameHost.isFinite else {
            throw RecorderError.unavailable("视频与相机时间证据不足")
        }
        let lines = try String(contentsOf: rawIMU, encoding: .utf8).split(whereSeparator: \.isNewline)
        let events = try lines.map { try JSONDecoder().decode(MotionEvent.self, from: Data($0.utf8)) }
        func timeline(_ kind: MotionEvent.Kind) throws -> [MotionEvent] {
            let values = events.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
            let before = values.first.map { firstFrameHost - $0.timestamp } ?? -.infinity
            let after = values.last.map { $0.timestamp - firstFrameHost - end } ?? -.infinity
            guard values.count >= 2, before >= 0, after >= 0 else {
                throw RecorderError.unavailable("IMU \(kind.rawValue) 未覆盖实际视频：片头 \(before) s、片尾 \(after) s；原始 MOV 与 IMU 已保留")
            }
            return values
        }
        let gyro = try timeline(.gyro), accel = try timeline(.accel)
        let cadence = VideoCadenceHealth(frames: video.frames, fps: expectedFPS ?? 1 / frameDuration)
        func maximumSampleGap(_ values: [MotionEvent]) -> Double {
            zip(values, values.dropFirst()).map { $1.timestamp - $0.timestamp }.max() ?? 0
        }
        let actualPreRoll = min(firstFrameHost - gyro[0].timestamp, firstFrameHost - accel[0].timestamp)
        let actualPostRoll = min(gyro.last!.timestamp, accel.last!.timestamp) - firstFrameHost - end
        completed("readIMU")
        func interpolate(_ values: [MotionEvent], _ seconds: Double) throws -> [Double] {
            let target = firstFrameHost + seconds
            var low = 0, high = values.count - 1
            while low + 1 < high {
                let mid = (low + high) / 2
                if values[mid].timestamp <= target { low = mid } else { high = mid }
            }
            let a = values[low], b = values[high], gap = b.timestamp - a.timestamp
            guard gap > 0, gap <= maximumGap else { throw RecorderError.unavailable("IMU 插值间隔超过 30 ms") }
            let f = (target - a.timestamp) / gap
            return [a.x + (b.x-a.x)*f, a.y + (b.y-a.y)*f, a.z + (b.z-a.z)*f]
        }
        let alignment = try CameraIntrinsicsRecorder.alignment(cameraFrames, video: video,
            firstHost: firstFrameHost, interval: frameDuration)
        let frameEvidence = alignment.frames
        completed("alignCameraIntrinsics")
        let matrix = (0..<9).map { element in
            frameEvidence.reduce(0.0) { $0 + $1.matrix[element] } / Double(frameEvidence.count)
        }
        let intrinsicSource = alignment.interpolatedCount + alignment.nearestFallbackCount == 0
            ? "CameraIntrinsicMatrix" : "CameraIntrinsicMatrix with estimated missing frames"
        let profile: [String: Any] = ["camera_brand": "Apple", "camera_model": camera,
            "lens_model": lens, "calibrated_by": "GyroCine",
            "calib_dimension": ["w": video.width, "h": video.height],
            "orig_dimension": ["w": video.width, "h": video.height],
            "output_dimension": ["w": orientation.isPortrait ? video.height : video.width,
                                 "h": orientation.isPortrait ? video.width : video.height],
            "distortion_model": "opencv_standard", "official": false,
            "fisheye_params": ["camera_matrix": [Array(matrix[0..<3]), Array(matrix[3..<6]), Array(matrix[6..<9])],
                "distortion_coeffs": Array(repeating: 0.0, count: 8)]]
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        let note = try JSONSerialization.data(withJSONObject: ["source_camera": camera,
            "transport": mode, "timing": timingSource ?? "MOV first frame PTS mapped from MovieFileOutput startPTS; optical sync unverified",
            "exposure_timing_model": exposureTimingModel.rawValue,
            "exposure_source": "AVCaptureDevice state sampled at camera callback; not frame-embedded exposure metadata",
            "exposure_timing_measured": false,
            "frame_readout_seconds": 0,
            "frame_readout_source": "unknown; modeled as zero, not measured and not inferred from FPS",
            "telemetry_packets_per_video_frame": true,
            "pre_roll_ms": Int((actualPreRoll * 1000).rounded()),
            "post_roll_ms": Int((actualPostRoll * 1000).rounded()), "lens_profile": profile,
            "intrinsic_source": intrinsicSource, "intrinsic_frame_count": frameEvidence.count,
            "lens_profile_source": "Apple sampled K mean; distortion uncalibrated",
            "intrinsic_interpolated_frame_count": alignment.interpolatedCount,
            "intrinsic_nearest_fallback_frame_count": alignment.nearestFallbackCount,
            "intrinsic_max_nearest_time_error_ms": alignment.maximumNearestError * 1000,
            "intrinsic_mean": matrix, "rotation_degrees": orientation.degrees,
            "video_max_frame_gap_ms": cadence.maximumGap * 1000,
            "video_estimated_missing_frames": cadence.missingFrames,
            "gyro_max_sample_gap_ms": maximumSampleGap(gyro) * 1000,
            "accel_max_sample_gap_ms": maximumSampleGap(accel) * 1000] as [String: Any], options: [.sortedKeys])
        var packets: [Data] = [], durations: [UInt32] = []
        if mode == "SonyMov" {
            let count = max(1, Int(ceil(end * 100)))
            var sampleIndex = 0
            // Gyroflow indexes Sony exposure offsets by VIDEO frame. Group the
            // unchanged global ~100 Hz grid into one RTMD packet per frame;
            // high-FPS frames may legitimately contain zero IMU samples.
            for (index, frame) in video.frames.enumerated() {
                let start = frame.pts - first
                let next = index + 1 < video.frames.count ? video.frames[index + 1].pts - first : end
                var samples: [EmbeddedTelemetryExporter.Sample] = []
                while sampleIndex < count {
                    let time = Double(sampleIndex) * end / Double(count)
                    guard time < next else { break }
                    samples.append(.init(time: time, gyro: try interpolate(gyro, time), accel: try interpolate(accel, time)))
                    sampleIndex += 1
                }
                let exposure = frameEvidence[index].exposure
                let timing = EmbeddedTelemetryExporter.SonyTiming(exposure: exposure,
                    firstRowLatchOffset: exposureTimingModel.firstRowLatchOffset(exposure: exposure),
                    firstIMUOffset: (samples.first?.time ?? start) - start)
                packets.append(try EmbeddedTelemetryExporter.sonyPacket(samples, matrix: frameEvidence[index].matrix,
                    width: video.width, height: video.height, timing: timing))
                durations.append(UInt32(max(1, Int64((next * 1e6).rounded()) - Int64((start * 1e6).rounded()))))
            }
        } else {
            var samples = [EmbeddedTelemetryExporter.Sample(time: 0,
                gyro: try interpolate(gyro, 0), accel: try interpolate(accel, 0))]
            for event in gyro {
                let time = event.timestamp - firstFrameHost
                if time > 0 && time < end {
                    samples.append(.init(time: time, gyro: [event.x, event.y, event.z],
                        accel: try interpolate(accel, time)))
                }
            }
            samples.append(.init(time: end, gyro: try interpolate(gyro, end), accel: try interpolate(accel, end)))
            var cursor = 0
            let boundedVideo = ActualVideoInfo(frames: video.frames, width: video.width,
                height: video.height, duration: end, codecFourCC: video.codecFourCC)
            for (index, frame) in video.frames.enumerated() {
                let start = frame.pts - first
                let next = index+1 < video.frames.count ? video.frames[index+1].pts-first : end
                let evidence = CaptureFrameEvidence(sourcePTSSeconds: frame.pts,
                    cameraIntrinsicMatrix: frameEvidence[index].matrix, intrinsicSource: intrinsicSource,
                    activeVideoStabilizationMode: 0, deviceExposureDurationAtCallbackSeconds: frameEvidence[index].exposure,
                    deviceISOAtCallback: frameEvidence[index].iso)
                var frameSamples: [EmbeddedTelemetryExporter.Sample] = []
                while cursor < samples.count && (samples[cursor].time < next || index == video.frames.count-1) {
                    frameSamples.append(samples[cursor]); cursor += 1
                }
                packets.append(try EmbeddedTelemetryExporter.protobufPacket(index: index, pts: start,
                    evidence: evidence, samples: frameSamples,
                    header: index == 0 ? EmbeddedTelemetryExporter.protobufHeader(video: boundedVideo,
                        fps: 1/frameDuration, camera: camera, lens: lens, profile: profileData, note: note, rotationDegrees: orientation.degrees) : nil,
                    timingModel: exposureTimingModel))
                durations.append(UInt32(max(1, Int64((next*1e6).rounded()) - Int64((start*1e6).rounded()))))
            }
        }
        completed("buildTelemetryPackets")
        var atoms = MOVTelemetryMuxer.box("rmin", note)
        if mode == "SonyMov" {
            let xml = "<Compatibility manufacturer=\"Sony\" modelName=\"GyroCine \(camera) compatibility\"><Lens modelName=\"Apple per-frame K\"/></Compatibility>"
            atoms += MOVTelemetryMuxer.box("xml ", Data(xml.utf8))
        }
        try MOVTelemetryMuxer.append(to: movie, kind: mode == "SonyMov" ? "rtmd" : "gyrf",
            packets: packets, durations: durations, note: atoms)
        completed("appendAndSyncMOV")
        if !retainDebug {
            try? FileManager.default.removeItem(at: rawIMU)
            try? FileManager.default.removeItem(at: cameraFrames)
        }
        return (samplesCount(gyro, firstFrameHost, end), firstFrameHost - gyro[0].timestamp,
            gyro.last!.timestamp - firstFrameHost - end)
    }

    private static func samplesCount(_ events: [MotionEvent], _ first: Double, _ end: Double) -> Int {
        events.filter { $0.timestamp >= first && $0.timestamp <= first + end }.count + 2
    }
}

/// Durable parameters use relative paths so reinstall/container relocation is safe.
struct PendingIMUJob: Codable {
    let movieName: String
    let imuName: String
    let framesName: String
    let firstHost: Double
    let orientation: RecordingOrientation
    let camera: String
    let lens: String
    let mode: String
    let retainDebug: Bool
    var externalMovieBookmark: Data? = nil
    var expectedVideoCodec: String? = nil
    var expectedFPS: Double? = nil
    var ready = false
    var recordingFailure: String?
    var recordingWarning: String?
    var intrinsicsUnavailableReason: String?
    var timingSource: String? = nil
    var exposureTimingModel: ExposureTimingModel? = nil

    func url(in directory: URL) -> URL {
        directory.appendingPathComponent(movieName).appendingPathExtension("pending-imu.json")
    }
    func save(in directory: URL) throws {
        try JSONEncoder().encode(self).write(to: url(in: directory), options: .atomic)
    }
    /// Move only the job manifest out of the automatic retry queue; preserve all media and diagnostics.
    static func retire(_ file: URL) throws {
        let suffix = ".pending-imu.json"
        guard file.lastPathComponent.hasSuffix(suffix) else { return }
        let target = file.deletingLastPathComponent().appendingPathComponent(
            String(file.lastPathComponent.dropLast(suffix.count)) + ".failed-imu.json")
        // Atomic replacement preserves the latest manifest if an older failed job exists.
        try Data(contentsOf: file).write(to: target, options: .atomic)
        try FileManager.default.removeItem(at: file)
    }
    static func isPermanentFailure(_ reason: String) -> Bool {
        ["50 ms", "30 ms", "逐帧 K", "没有与 MOV 像素尺寸一致的有效 K 数据",
         "视频帧不足", "视频帧率严重不足", "视频帧时间异常", "Invalid recovery file paths",
         "Local recording no longer exists"].contains { reason.contains($0) }
    }
    func complete(in directory: URL, progress: ((String, Double) -> Void)? = nil) throws {
        guard [movieName, imuName, framesName].allSatisfy({ !$0.isEmpty && URL(fileURLWithPath: $0).lastPathComponent == $0 }),
              movieName.lowercased().hasSuffix(".mov"),
              imuName == String(movieName.dropLast(4)) + ".imu_raw.jsonl",
              framesName == String(movieName.dropLast(4)) + ".camera_frames.jsonl" else {
            throw RecorderError.unavailable("Invalid recovery file paths")
        }
        var stale = false
        let localMovie = directory.appendingPathComponent(movieName)
        let movie = try externalMovieBookmark.map {
            try URL(resolvingBookmarkData: $0, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
        } ?? (FileManager.default.fileExists(atPath: localMovie.path) ? localMovie :
              FileManager.default.fileExists(atPath: RecordingStoragePaths.movieDirectory.appendingPathComponent(movieName).path)
              ? RecordingStoragePaths.movieDirectory.appendingPathComponent(movieName)
              : RecordingStoragePaths.legacyDirectory.appendingPathComponent(movieName))
        guard !stale, movie.lastPathComponent == movieName else {
            throw RecorderError.unavailable("SSD 素材授权已失效，请重新连接 SSD；原始 IMU 已保留")
        }
        let accessing = externalMovieBookmark != nil && movie.startAccessingSecurityScopedResource()
        guard externalMovieBookmark == nil || accessing else {
            throw RecorderError.unavailable("无法访问 SSD 素材，请重新连接 SSD；原始 IMU 已保留")
        }
        defer { if accessing { movie.stopAccessingSecurityScopedResource() } }
        // Missing local media cannot recover. An offline SSD must remain retryable.
        if externalMovieBookmark == nil && !FileManager.default.fileExists(atPath: movie.path) {
            throw RecorderError.unavailable("Local recording no longer exists")
        }
        if let recordingFailure { throw RecorderError.unavailable(recordingFailure) }
        try MOVTelemetryMuxer.recoverIfNeeded(movie)
        if intrinsicsUnavailableReason != nil {
            let video = try MovieIMUFinalizer.inspect(movie)
            if let expectedFPS, video.duration.isFinite, video.duration > 0 {
                let minimum = max(2, Int((video.duration * expectedFPS * 0.8).rounded(.down)))
                guard video.frames.count >= minimum else {
                    throw RecorderError.unavailable("MOV 视频帧率严重不足：\(video.frames.count)/\(minimum) 帧；原始文件已保留")
                }
                try VideoCadenceHealth(frames: video.frames, fps: expectedFPS).validate(fps: expectedFPS)
            }
            guard !AVURLAsset(url: movie).tracks(withMediaType: .audio).isEmpty else {
                throw RecorderError.unavailable("MOV 音频轨校验失败；原始文件已保留")
            }
            // Keep raw IMU for diagnosis. Without measured K we cannot publish a
            // Gyroflow-compatible embedded telemetry track or claim IMU success.
            try FileManager.default.removeItem(at: url(in: directory))
            return
        }
        if let expectedVideoCodec, ["aprn", "aprh"].contains(expectedVideoCodec) {
            let asset = AVURLAsset(url: movie)
            guard let track = asset.tracks(withMediaType: .video).first,
                  let description = track.formatDescriptions.first else {
                throw RecorderError.unavailable("RAW MOV 没有视频轨；原始文件已保留")
            }
            let code = CMFormatDescriptionGetMediaSubType(description as! CMFormatDescription)
            let actual = String(bytes: (0..<4).map { UInt8((code >> (24 - $0 * 8)) & 255) }, encoding: .ascii) ?? "unknown"
            guard actual == expectedVideoCodec else {
                throw RecorderError.unavailable("RAW 编码不符：期望 \(expectedVideoCodec)，实际 \(actual)；原始文件已保留")
            }
        }
        // A crash after MOV commit but before job removal must not append another track.
        if !MOVTelemetryMuxer.hasTelemetry(movie) {
            _ = try MovieIMUFinalizer.finalize(movie: movie,
                rawIMU: directory.appendingPathComponent(imuName), firstFrameHost: firstHost,
                cameraFrames: directory.appendingPathComponent(framesName), orientation: orientation,
                camera: camera, lens: lens, mode: mode, retainDebug: true,
                expectedFPS: expectedFPS, timingSource: timingSource,
                exposureTimingModel: exposureTimingModel ?? .presentationMidpoint, progress: progress)
        }
        // The full compressed-video scan above is needed for frame PTS only once.
        // Verify the committed metadata sample index and original AV tracks
        // without reading multi-GB video payloads again.
        guard MOVTelemetryMuxer.hasTelemetry(movie) else {
            throw RecorderError.unavailable("MOV 缺少有效 IMU 元数据轨；原始文件已保留")
        }
        let asset = AVURLAsset(url: movie)
        guard !asset.tracks(withMediaType: .video).isEmpty,
              !asset.tracks(withMediaType: .audio).isEmpty else {
            throw RecorderError.unavailable("MOV 视频或音频轨校验失败；原始文件已保留")
        }
        try FileManager.default.removeItem(at: url(in: directory))
        if !retainDebug {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(imuName))
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(framesName))
        }
    }
}
