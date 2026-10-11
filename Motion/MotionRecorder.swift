import CoreMotion
import Foundation

struct MotionEvent: Codable {
    enum Kind: String, Codable { case gyro, accel }
    let kind: Kind
    let timestamp: TimeInterval
    let x: Double
    let y: Double
    let z: Double
}

final class MotionRecorder {
    private let manager = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var handle: StagedRecordingLog?
    private var eventCount = 0
    private var firstGyroTimestamp: TimeInterval?
    private var latestGyroTimestamp: TimeInterval?
    private var writeFailure: String?
    private let encoder = JSONEncoder()
    private var gravityOrientation: RecordingOrientation?
    private var gravityTimestamp: TimeInterval = 0

    func startOrientationMonitoring() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] sample, _ in
            guard let self, let sample else { return }
            self.lock.lock(); defer { self.lock.unlock() }
            self.gravityTimestamp = sample.timestamp
            if let orientation = RecordingOrientation.fromGravity(x: sample.gravity.x, y: sample.gravity.y, z: sample.gravity.z) {
                self.gravityOrientation = orientation
            }
        }
    }

    var recordingDirection: RecordingOrientation? {
        lock.lock(); defer { lock.unlock() }
        guard ProcessInfo.processInfo.systemUptime - gravityTimestamp < 1 else { return nil }
        return gravityOrientation
    }

    var isAvailable: Bool { manager.isGyroAvailable && manager.isAccelerometerAvailable }
    var count: Int { lock.lock(); defer { lock.unlock() }; return eventCount }
    var gyroSpanSeconds: TimeInterval {
        lock.lock(); defer { lock.unlock() }
        guard let firstGyroTimestamp, let latestGyroTimestamp else { return 0 }
        return latestGyroTimestamp - firstGyroTimestamp
    }
    var error: String? { lock.lock(); defer { lock.unlock() }; return writeFailure }

    func start(at url: URL) throws {
        guard isAvailable else { throw RecorderError.unavailable("Raw gyro or accelerometer unavailable") }
        lock.lock()
        eventCount = 0
        firstGyroTimestamp = nil
        latestGyroTimestamp = nil
        writeFailure = nil
        lock.unlock()
        handle = try StagedRecordingLog(destination: url)
        queue.maxConcurrentOperationCount = 1
        manager.gyroUpdateInterval = 1.0 / 100.0
        manager.accelerometerUpdateInterval = 1.0 / 100.0
        manager.startGyroUpdates(to: queue) { [weak self] sample, error in
            guard let sample else { self?.setError(error?.localizedDescription ?? "gyro update failed"); return }
            self?.append(MotionEvent(kind: .gyro, timestamp: sample.timestamp,
                                     x: sample.rotationRate.x, y: sample.rotationRate.y, z: sample.rotationRate.z))
        }
        manager.startAccelerometerUpdates(to: queue) { [weak self] sample, error in
            guard let sample else { self?.setError(error?.localizedDescription ?? "accelerometer update failed"); return }
            self?.append(MotionEvent(kind: .accel, timestamp: sample.timestamp,
                                     x: sample.acceleration.x * 9.80665,
                                     y: sample.acceleration.y * 9.80665,
                                     z: sample.acceleration.z * 9.80665))
        }
    }

    private func setError(_ value: String) {
        lock.lock(); writeFailure = value; lock.unlock()
    }

    private func append(_ sample: MotionEvent) {
        lock.lock(); defer { lock.unlock() }
        do {
            let data = try encoder.encode(sample)
            try handle?.write(contentsOf: data + Data([0x0A]))
            eventCount += 1
            if sample.kind == .gyro {
                if firstGyroTimestamp == nil { firstGyroTimestamp = sample.timestamp }
                latestGyroTimestamp = sample.timestamp
            }
        } catch { writeFailure = error.localizedDescription }
    }

    func stop() {
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
        queue.waitUntilAllOperationsAreFinished()
        lock.lock(); defer { lock.unlock() }
        do { try handle?.publish() }
        catch { writeFailure = error.localizedDescription }
        handle = nil
    }
}
