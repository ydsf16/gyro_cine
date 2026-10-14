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
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? RecorderError.unavailable("无法读取视频帧时间") }
        var frames: [ActualVideoFrame] = []
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
        guard reader.status == .completed, frames.count >= 2 else {
            throw reader.error ?? RecorderError.unavailable("MOV 视频帧不足")
        }
        frames.sort { $0.pts < $1.pts }
        let dims = CMVideoFormatDescriptionGetDimensions(format as! CMVideoFormatDescription)
        let code = CMFormatDescriptionGetMediaSubType(format as! CMFormatDescription)
        let fourCC = String(bytes: (0..<4).map { UInt8((code >> (24 - $0 * 8)) & 255) }, encoding: .ascii) ?? "unknown"
        return ActualVideoInfo(frames: frames, width: Int(dims.width), height: Int(dims.height),
            duration: asset.duration.seconds, codecFourCC: fourCC)
    }

    static func finalize(movie: URL, rawIMU: URL, firstFrameHost: Double,
                         cameraFrames: URL,
                         camera: String, lens: String, mode: String, retainDebug: Bool) throws -> (Int, Double, Double) {
        let video = try inspect(movie)
        let first = video.frames[0].pts
        let intervals = zip(video.frames, video.frames.dropFirst()).map { $1.pts - $0.pts }.filter { $0 > 0 }
        let frameDuration = intervals.sorted()[intervals.count / 2]
        let end = video.frames.last!.pts - first + frameDuration
        guard end > 0, firstFrameHost.isFinite else {
            throw RecorderError.unavailable("视频与相机时间证据不足")
        }
        let lines = try String(contentsOf: rawIMU, encoding: .utf8).split(whereSeparator: \.isNewline)
        let events = try lines.map { try JSONDecoder().decode(MotionEvent.self, from: Data($0.utf8)) }
        func timeline(_ kind: MotionEvent.Kind) throws -> [MotionEvent] {
            let values = events.filter { $0.kind == kind }.sorted { $0.timestamp < $1.timestamp }
            guard values.count >= 2, values.first!.timestamp <= firstFrameHost - margin,
                  values.last!.timestamp >= firstFrameHost + end + margin else {
                throw RecorderError.unavailable("IMU 没有覆盖视频首尾各 50 ms；原始 MOV 与 IMU 已保留")
            }
            return values
        }
        let gyro = try timeline(.gyro), accel = try timeline(.accel)
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
        let frameEvidence = try CameraIntrinsicsRecorder.aligned(cameraFrames, video: video,
            firstHost: firstFrameHost, interval: frameDuration)
        let matrix = (0..<9).map { element in
            frameEvidence.reduce(0.0) { $0 + $1.matrix[element] } / Double(frameEvidence.count)
        }
        let profile: [String: Any] = ["camera_brand": "Apple", "camera_model": camera,
            "lens_model": lens, "calibrated_by": "Apple per-frame K mean; distortion uncalibrated",
            "calib_dimension": ["w": video.width, "h": video.height],
            "orig_dimension": ["w": video.width, "h": video.height],
            "distortion_model": "opencv_standard", "official": false,
            "fisheye_params": ["camera_matrix": [Array(matrix[0..<3]), Array(matrix[3..<6]), Array(matrix[6..<9])],
                "distortion_coeffs": Array(repeating: 0.0, count: 8)]]
        let profileData = try JSONSerialization.data(withJSONObject: profile, options: [.sortedKeys])
        let note = try JSONSerialization.data(withJSONObject: ["source_camera": camera,
            "transport": mode, "timing": "MOV first frame PTS mapped from MovieFileOutput startPTS; optical sync unverified",
            "pre_roll_ms": 50, "post_roll_ms": 50, "lens_profile": profile,
            "intrinsic_source": "CameraIntrinsicMatrix", "intrinsic_frame_count": frameEvidence.count,
            "intrinsic_mean": matrix] as [String: Any], options: [.sortedKeys])
        var packets: [Data] = [], durations: [UInt32] = []
        if mode == "SonyMov" {
            let count = max(1, Int(ceil(end * 100)))
            var frameIndex = 0
            for i in 0..<count {
                let time = Double(i) * end / Double(count)
                let sample = EmbeddedTelemetryExporter.Sample(time: time,
                    gyro: try interpolate(gyro, time), accel: try interpolate(accel, time))
                while frameIndex + 1 < video.frames.count && video.frames[frameIndex + 1].pts - first <= time { frameIndex += 1 }
                packets.append(try EmbeddedTelemetryExporter.sonyPacket(sample, matrix: frameEvidence[max(0, frameIndex)].matrix,
                    width: video.width, height: video.height))
                let next = Double(i+1) * end / Double(count)
                durations.append(UInt32(max(1, Int64((next * 1e6).rounded()) - Int64((time * 1e6).rounded()))))
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
                    cameraIntrinsicMatrix: frameEvidence[index].matrix, intrinsicSource: "CameraIntrinsicMatrix",
                    activeVideoStabilizationMode: 0, deviceExposureDurationAtCallbackSeconds: frameEvidence[index].exposure,
                    deviceISOAtCallback: frameEvidence[index].iso)
                var frameSamples: [EmbeddedTelemetryExporter.Sample] = []
                while cursor < samples.count && (samples[cursor].time < next || index == video.frames.count-1) {
                    frameSamples.append(samples[cursor]); cursor += 1
                }
                packets.append(try EmbeddedTelemetryExporter.protobufPacket(index: index, pts: start,
                    evidence: evidence, samples: frameSamples,
                    header: index == 0 ? EmbeddedTelemetryExporter.protobufHeader(video: boundedVideo,
                        fps: 1/frameDuration, camera: camera, lens: lens, profile: profileData, note: note) : nil))
                durations.append(UInt32(max(1, Int64((next*1e6).rounded()) - Int64((start*1e6).rounded()))))
            }
        }
        var atoms = MOVTelemetryMuxer.box("rmin", note)
        if mode == "SonyMov" {
            let xml = "<Compatibility manufacturer=\"Sony\" modelName=\"GyroCine \(camera) compatibility\"><Lens modelName=\"Apple per-frame K\"/></Compatibility>"
            atoms += MOVTelemetryMuxer.box("xml ", Data(xml.utf8))
        }
        try MOVTelemetryMuxer.append(to: movie, kind: mode == "SonyMov" ? "rtmd" : "gyrf",
            packets: packets, durations: durations, note: atoms)
        // Reopen the completed container before reporting success.
        _ = try inspect(movie)
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
