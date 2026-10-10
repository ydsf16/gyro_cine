import CoreMedia
import Foundation

struct ClockEvidence: Codable {
    var firstVideoHostPTSSeconds: Double? = nil
    let firstVideoPTSSeconds: Double
    let hostClockAtFirstCallbackSeconds: Double
    let callbackMinusPTSSeconds: Double
    let method: String
    let hardwareReadoutTimeKnown: Bool
}

enum ClockAligner {
    static func hostTime(_ pts: CMTime, clock: CMClock?) throws -> Double {
        guard pts.isValid, pts.isNumeric, let clock else {
            throw RecorderError.unavailable("Capture synchronization clock unavailable")
        }
        let host = CMSyncConvertTime(pts, from: clock, to: CMClockGetHostTimeClock())
        guard host.isValid, host.isNumeric, host.seconds.isFinite else {
            throw RecorderError.unavailable("Capture timestamp conversion failed")
        }
        return host.seconds
    }

    static func evidence(firstPTS: CMTime, hostPTS: Double, callbackHostTime: Double) -> ClockEvidence {
        let pts = CMTimeGetSeconds(firstPTS)
        return ClockEvidence(firstVideoHostPTSSeconds: hostPTS, firstVideoPTSSeconds: pts,
                             hostClockAtFirstCallbackSeconds: callbackHostTime,
                             callbackMinusPTSSeconds: callbackHostTime - hostPTS,
                             method: "CMSyncConvertTime from AVCaptureSession.synchronizationClock to host clock; CoreMotion sample timestamps share the host epoch. Optical alignment still requires validation.",
                             hardwareReadoutTimeKnown: false)
    }

    static func degreesPerSecond(_ radiansPerSecond: Double) -> Double {
        radiansPerSecond * 180.0 / .pi
    }
}
