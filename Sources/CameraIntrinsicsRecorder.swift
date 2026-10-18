import AVFoundation

/// Consumes metadata only; never retains or copies camera pixel buffers.
final class CameraIntrinsicsRecorder: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct Frame: Codable {
        let hostTime: Double
        let width: Int
        let height: Int
        let matrix: [Double]
        let exposure: Double
        let iso: Float
    }
    let queue = DispatchQueue(label: "GyroCine.cameraIntrinsics")
    private var handle: FileHandle?
    private var clock: CMClock?
    private var camera: AVCaptureDevice?
    #if DEBUG
    weak var timestampProbe: CaptureStartTimestampProbe?
    #endif
    private var failure: Error?
    // Queue-owned, bounded diagnostics. No per-frame console or extra disk writes.
    private var received = 0
    private var failed = 0
    private var droppedReasons: [String: Int] = [:]
    private var lastHost: Double?
    private var maxGap = 0.0
    private var maxLatency = 0.0
    private var totalProcessing = 0.0
    private var maxProcessing = 0.0
    private var maxWrite = 0.0
    private var gapCount = 0
    private var gapExamples: [[String: Double]] = []
    private var expectedInterval = 0.0

    private static func hostNow() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }


    func diagnostics() -> [String: Any] {
        queue.sync {
            ["receivedFrames": received, "failedFrames": failed,
             "dataOutputDroppedReasons": droppedReasons,
             "expectedIntervalSeconds": expectedInterval,
             "maxPTSGapSeconds": maxGap, "longGapCount": gapCount,
             "firstGapExamples": gapExamples,
             "maxCallbackLatencySeconds": maxLatency,
             "meanProcessingSeconds": totalProcessing / Double(max(received, 1)),
             "maxProcessingSeconds": maxProcessing, "maxWriteSeconds": maxWrite]
        }
    }

    func start(at url: URL, clock: CMClock?, camera: AVCaptureDevice) throws {
        try queue.sync {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            self.clock = clock; self.camera = camera; failure = nil
            received = 0; failed = 0; droppedReasons = [:]; lastHost = nil
            maxGap = 0; maxLatency = 0; totalProcessing = 0
            maxProcessing = 0; maxWrite = 0; gapCount = 0; gapExamples = []
            let interval = camera.activeVideoMinFrameDuration.seconds
            expectedInterval = interval.isFinite && interval > 0 ? interval : 0
        }
    }

    func stop() throws {
        try queue.sync {
            defer { handle = nil; camera = nil; clock = nil }
            try handle?.synchronize(); try handle?.close()
            if let failure { throw failure }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        #if DEBUG
        timestampProbe?.recordVideo(sampleBuffer)
        #endif
        guard let handle, let camera else { return }
        let arrival = Self.hostNow()
        received += 1
        defer {
            let elapsed = Self.hostNow() - arrival
            totalProcessing += elapsed
            maxProcessing = max(maxProcessing, elapsed)
        }
        do {
            let host = try ClockAligner.hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), clock: clock)
            maxLatency = max(maxLatency, arrival - host)
            if let previous = lastHost {
                let gap = host - previous
                maxGap = max(maxGap, gap)
                if expectedInterval > 0 && gap > expectedInterval * 1.5 {
                    gapCount += 1
                    if gapExamples.count < 16 {
                        gapExamples.append(["hostTime": host, "gapSeconds": gap,
                                            "callbackLatencySeconds": arrival - host])
                    }
                }
            }
            lastHost = host
            guard let matrix = CaptureFrameEvidence.intrinsicMatrix(sampleBuffer),
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw RecorderError.unavailable("相机未提供逐帧真实 K")
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let frame = Frame(hostTime: host,
                width: Int(dimensions.width), height: Int(dimensions.height), matrix: matrix,
                exposure: camera.exposureDuration.seconds, iso: camera.iso)
            let bytes = try JSONEncoder().encode(frame) + Data([10])
            let writeStart = Self.hostNow()
            defer { maxWrite = max(maxWrite, Self.hostNow() - writeStart) }
            try handle.write(contentsOf: bytes)
        } catch { failed += 1; failure = error }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard handle != nil else { return }
        let reason = CMGetAttachment(sampleBuffer,
            key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil)
        let label = reason.map { String(describing: $0) } ?? "Unknown"
        droppedReasons[label, default: 0] += 1
    }

    /// Snapshot metadata synchronously, then write only value types off the RAW capture queue.
    /// No pixel/sample buffer is retained by the metadata writer.
    func recordNativeMetadata(_ sample: CMSampleBuffer, clock: CMClock?, camera: AVCaptureDevice) {
        let snapshot = Result { () throws -> Frame in
            guard let matrix = CaptureFrameEvidence.intrinsicMatrix(sample),
                  let format = CMSampleBufferGetFormatDescription(sample) else {
                throw RecorderError.unavailable("RAW 数据帧没有真实 K")
            }
            let size = CMVideoFormatDescriptionGetDimensions(format)
            return Frame(hostTime: try ClockAligner.hostTime(CMSampleBufferGetPresentationTimeStamp(sample), clock: clock),
                width: Int(size.width), height: Int(size.height), matrix: matrix,
                exposure: camera.exposureDuration.seconds, iso: camera.iso)
        }
        queue.async {
            guard let handle = self.handle else { return }
            self.received += 1
            do {
                let frame = try snapshot.get()
                if let previous = self.lastHost { self.maxGap = max(self.maxGap, frame.hostTime - previous) }
                self.lastHost = frame.hostTime
                try handle.write(contentsOf: JSONEncoder().encode(frame) + Data([10]))
            } catch { self.failed += 1; self.failure = error }
        }
    }

    struct Alignment {
        let frames: [Frame]
        let interpolatedCount: Int
        let nearestFallbackCount: Int
        let maximumNearestError: Double
    }

    /// Use measured K where available. A dropped K callback does not discard
    /// valid video and IMU; estimated frames are counted in MOV metadata.
    static func alignment(_ url: URL, video: ActualVideoInfo, firstHost: Double, interval: Double) throws -> Alignment {
        let lines = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
        let decoded = try lines.map { try JSONDecoder().decode(Frame.self, from: Data($0.utf8)) }
        let valid = decoded.filter { frame in
            frame.width == video.width && frame.height == video.height &&
                frame.matrix.count == 9 && frame.matrix.allSatisfy(\.isFinite) &&
                frame.hostTime.isFinite && frame.exposure.isFinite && frame.exposure > 0 &&
                frame.iso.isFinite && frame.iso > 0
        }
        let samples = valid.sorted { $0.hostTime < $1.hostTime }
        guard !samples.isEmpty else { throw RecorderError.unavailable("没有与 MOV 像素尺寸一致的有效 K 数据") }
        var cursor = 0
        var frames: [Frame] = []
        frames.reserveCapacity(video.frames.count)
        var interpolatedCount = 0, nearestFallbackCount = 0
        var maximumNearestError = 0.0
        for frame in video.frames {
            let target = firstHost + frame.pts - video.frames[0].pts
            while cursor + 1 < samples.count && abs(samples[cursor + 1].hostTime - target) < abs(samples[cursor].hostTime - target) { cursor += 1 }
            let sample = samples[cursor]
            let error = abs(sample.hostTime - target)
            maximumNearestError = max(maximumNearestError, error)
            // MovieFileOutput and VideoDataOutput can stamp the same capture at
            // slightly different phases. Match the nearest K sample within
            // half a frame plus 2 ms of clock/PTS jitter.
            let tolerance = min(0.012, interval * 0.5 + 0.002)
            if error <= tolerance {
                frames.append(sample)
                continue
            }
            let before = sample.hostTime <= target ? cursor : cursor - 1
            let after = sample.hostTime > target ? cursor : cursor + 1
            if before >= 0, after < samples.count {
                let a = samples[before], b = samples[after]
                let gap = b.hostTime - a.hostTime
                if gap > 0, gap <= interval * 2.1 + 0.002 {
                    let fraction = (target - a.hostTime) / gap
                    let matrix = zip(a.matrix, b.matrix).map { pair in
                        pair.0 + (pair.1 - pair.0) * fraction
                    }
                    let exposure = a.exposure + (b.exposure - a.exposure) * fraction
                    let iso = a.iso + (b.iso - a.iso) * Float(fraction)
                    frames.append(Frame(hostTime: target, width: video.width, height: video.height,
                        matrix: matrix, exposure: exposure, iso: iso))
                    interpolatedCount += 1
                    continue
                }
            }
            frames.append(sample)
            nearestFallbackCount += 1
        }
        return Alignment(frames: frames, interpolatedCount: interpolatedCount,
            nearestFallbackCount: nearestFallbackCount, maximumNearestError: maximumNearestError)
    }

    static func aligned(_ url: URL, video: ActualVideoInfo, firstHost: Double, interval: Double) throws -> [Frame] {
        try alignment(url, video: video, firstHost: firstHost, interval: interval).frames
    }
}
