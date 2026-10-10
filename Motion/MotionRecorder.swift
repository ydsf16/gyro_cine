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
    private var handle: FileHandle?
    private var eventCount = 0
    private var writeFailure: String?
    private let encoder = JSONEncoder()

    var isAvailable: Bool { manager.isGyroAvailable && manager.isAccelerometerAvailable }
    var count: Int { lock.lock(); defer { lock.unlock() }; return eventCount }
    var error: String? { lock.lock(); defer { lock.unlock() }; return writeFailure }

    func start(at url: URL) throws {
        guard isAvailable else { throw RecorderError.unavailable("Raw gyro or accelerometer unavailable") }
        lock.lock()
        eventCount = 0
        writeFailure = nil
        lock.unlock()
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw RecorderError.unavailable("Cannot create raw IMU file")
        }
        handle = try FileHandle(forWritingTo: url)
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
        } catch { writeFailure = error.localizedDescription }
    }

    func stop() {
        manager.stopGyroUpdates()
        manager.stopAccelerometerUpdates()
        queue.waitUntilAllOperationsAreFinished()
        lock.lock(); defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
