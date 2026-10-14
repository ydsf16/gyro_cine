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
    private var failure: Error?

    func start(at url: URL, clock: CMClock?, camera: AVCaptureDevice) throws {
        try queue.sync {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
            self.clock = clock; self.camera = camera; failure = nil
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
        guard let handle, let camera else { return }
        do {
            guard let matrix = CaptureFrameEvidence.intrinsicMatrix(sampleBuffer),
                  let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                throw RecorderError.unavailable("相机未提供逐帧真实 K")
            }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format)
            let frame = Frame(hostTime: try ClockAligner.hostTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), clock: clock),
                width: Int(dimensions.width), height: Int(dimensions.height), matrix: matrix,
                exposure: camera.exposureDuration.seconds, iso: camera.iso)
            try handle.write(contentsOf: JSONEncoder().encode(frame) + Data([10]))
        } catch { failure = error }
    }

    /// Match each encoded MOV frame in the common host clock; reject missing evidence.
    static func aligned(_ url: URL, video: ActualVideoInfo, firstHost: Double, interval: Double) throws -> [Frame] {
        let samples = try String(contentsOf: url, encoding: .utf8).split(whereSeparator: \.isNewline)
            .map { try JSONDecoder().decode(Frame.self, from: Data($0.utf8)) }.sorted { $0.hostTime < $1.hostTime }
        guard !samples.isEmpty else { throw RecorderError.unavailable("没有逐帧 K 数据") }
        var cursor = 0
        return try video.frames.map { frame in
            let target = firstHost + frame.pts - video.frames[0].pts
            while cursor + 1 < samples.count && abs(samples[cursor + 1].hostTime - target) < abs(samples[cursor].hostTime - target) { cursor += 1 }
            let sample = samples[cursor]
            guard abs(sample.hostTime - target) <= min(0.01, interval * 0.45),
                  sample.width == video.width, sample.height == video.height,
                  sample.matrix.count == 9, sample.matrix.allSatisfy(\.isFinite) else {
                throw RecorderError.unavailable("逐帧 K 与 MOV 时间或像素尺寸不匹配；保留原始文件")
            }
            return sample
        }
    }
}
