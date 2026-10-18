import AVFoundation

/// Debug-only timing probe. Reads sample timestamps, never pixel or audio payloads.
final class CaptureStartTimestampProbe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    let audioOutput = AVCaptureAudioDataOutput()
    let audioQueue = DispatchQueue(label: "GyroCine.captureStartAudioProbe")
    private let lock = NSLock()
    private var armed = false
    private var videoPTS: [Double] = []
    private var audioPTS: [Double] = []

    override init() {
        super.init()
        audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
    }

    func arm() {
        lock.lock(); defer { lock.unlock() }
        videoPTS.removeAll(keepingCapacity: true)
        audioPTS.removeAll(keepingCapacity: true)
        armed = true
    }

    func recordVideo(_ sample: CMSampleBuffer) {
        append(CMSampleBufferGetPresentationTimeStamp(sample).seconds, video: true)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        append(CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds, video: false)
    }

    private func append(_ pts: Double, video: Bool) {
        guard pts.isFinite else { return }
        lock.lock(); defer { lock.unlock() }
        guard armed else { return }
        if video {
            if videoPTS.count < 120 { videoPTS.append(pts) }
        } else if audioPTS.count < 240 {
            audioPTS.append(pts)
        }
    }

    func snapshot(startPTS: CMTime, clock: CMClock?) -> [String: Any] {
        lock.lock()
        armed = false
        let video = videoPTS.sorted(), audio = audioPTS.sorted()
        lock.unlock()
        let start = startPTS.seconds
        func summary(_ values: [Double]) -> [String: Any] {
            let earlier = values.last(where: { $0 <= start })
            let later = values.first(where: { $0 >= start })
            let nearest = [earlier, later].compactMap { $0 }.min(by: { abs($0 - start) < abs($1 - start) })
            return ["count": values.count, "firstPTS": values.first ?? -1,
                    "lastBeforeStartPTS": earlier ?? -1, "firstAtOrAfterStartPTS": later ?? -1,
                    "nearestPTS": nearest ?? -1,
                    "nearestMinusStartMs": nearest.map { ($0 - start) * 1000 } ?? -9999]
        }
        return ["startPTS": start, "startHost": (try? ClockAligner.hostTime(startPTS, clock: clock)) ?? -1,
                "video": summary(video), "audio": summary(audio)]
    }
}
