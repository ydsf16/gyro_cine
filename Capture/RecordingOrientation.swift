import UIKit

/// Rotation of the sensor-native landscape buffer for display. Frozen when REC is pressed.
enum RecordingOrientation: Int, Codable {
    case landscapeRight = 0
    case portrait = 90
    case landscapeLeft = 180
    case portraitUpsideDown = 270

    var isPortrait: Bool { self == .portrait || self == .portraitUpsideDown }
    static func fromGravity(x: Double, y: Double, z: Double) -> Self? {
        guard x.isFinite, y.isFinite, z.isFinite, max(abs(x), abs(y)) > 0.55 else { return nil }
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
