import UIKit
import CoreMotion

/// Rotation of the sensor-native landscape buffer for display. Frozen when REC is pressed.
enum RecordingOrientation: Int, Codable {
    case landscapeRight = 0
    case portrait = 90
    case landscapeLeft = 180
    case portraitUpsideDown = 270

    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
    static func fromGravity(x: Double, y: Double, z: Double) -> Self? {
        guard x.isFinite, y.isFinite, z.isFinite, max(abs(x), abs(y)) > 0.35, abs(abs(x) - abs(y)) > 0.15 else { return nil }
        if abs(x) > abs(y) { return x < 0 ? .landscapeRight : .landscapeLeft }
        return y < 0 ? .portrait : .portraitUpsideDown
    }
    var degrees: Int { rawValue }
    func movieTransform(width: Int, height: Int) -> CGAffineTransform {
        switch self {
        case .landscapeRight: return .identity
        case .portrait: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(height), ty: 0)
        case .landscapeLeft: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(width), ty: CGFloat(height))
        case .portraitUpsideDown: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(width))
        }
    }
    /// Capture buffers stay sensor-native (videoRotationAngle = 0).
    /// MOV presentation rotation must not rotate telemetry relative to those buffers.
    var imuOrientation: String { "XYZ" }
    func remap(_ vector: [Double]) -> [Double] { vector }
}

/// Snapshot frozen when REC is accepted; independent of interface orientation and portrait lock.
struct RecordingGravity: Codable {
    let timestamp: Double
    let x: Double
    let y: Double
    let z: Double
    func direction(at uptime: Double) -> RecordingOrientation? {
        let age = uptime - timestamp
        guard age.isFinite, age >= 0, age <= 0.5 else { return nil }
        return RecordingOrientation.fromGravity(x: x, y: y, z: z)
    }
}

extension RecordingOrientation {
    static func previewAngle(for interface: UIInterfaceOrientation) -> CGFloat? {
        switch interface {
        case .portrait: return 90
        case .portraitUpsideDown: return 270
        case .landscapeLeft: return 180
        case .landscapeRight: return 0
        default: return nil
        }
    }

    func matchesMovieTransform(_ actual: CGAffineTransform, width: Int, height: Int) -> Bool {
        let expected = movieTransform(width: width, height: height)
        return zip([actual.a, actual.b, actual.c, actual.d, actual.tx, actual.ty],
                   [expected.a, expected.b, expected.c, expected.d, expected.tx, expected.ty])
            .allSatisfy { $0.isFinite && abs($0 - $1) < 0.01 }
    }
}

/// Gravity cannot determine in-plane rotation when the phone lies flat. Preserve
/// the last unambiguous physical direction; never consult interface rotation lock.
struct RecordingDirectionTracker {
    private(set) var lastDirection: RecordingOrientation?
    struct Decision {
        let orientation: RecordingOrientation
        let gravity: RecordingGravity?
        let source: String
    }
    mutating func resolve(_ gravity: RecordingGravity?, at uptime: Double) -> Decision {
        if let gravity, let direction = gravity.direction(at: uptime) {
            lastDirection = direction
            return Decision(orientation: direction, gravity: gravity, source: "currentGravity")
        }
        return Decision(orientation: lastDirection ?? .portrait, gravity: gravity,
                        source: lastDirection == nil ? "defaultPortrait" : "lastUnambiguousGravity")
    }
}

/// Low-rate fused gravity is independent of interface orientation and rotation lock.
final class GravityOrientationMonitor {
    private let motion = CMMotionManager()
    private let queue = OperationQueue()
    private let lock = NSLock()
    private var gravity: RecordingGravity?
    private var tracker = RecordingDirectionTracker()

    init() {
        queue.name = "GyroCine.gravity"
        queue.maxConcurrentOperationCount = 1
    }
    func start() {
        guard motion.isDeviceMotionAvailable else { return }
        motion.deviceMotionUpdateInterval = 1.0 / 20
        motion.startDeviceMotionUpdates(to: queue) { [weak self] data, _ in
            guard let self, let data else { return }
            let value = RecordingGravity(timestamp: data.timestamp, x: data.gravity.x,
                                         y: data.gravity.y, z: data.gravity.z)
            self.lock.lock()
            self.gravity = value
            _ = self.tracker.resolve(value, at: ProcessInfo.processInfo.systemUptime)
            self.lock.unlock()
        }
    }
    func snapshot() -> RecordingDirectionTracker.Decision {
        lock.lock(); defer { lock.unlock() }
        return tracker.resolve(gravity, at: ProcessInfo.processInfo.systemUptime)
    }
    deinit { motion.stopDeviceMotionUpdates() }
}
