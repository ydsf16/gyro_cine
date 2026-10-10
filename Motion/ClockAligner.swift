import CoreMedia
import Foundation

struct ClockEvidence: Codable {
    let firstVideoPTSSeconds: Double
    let hostClockAtFirstCallbackSeconds: Double
    let callbackMinusPTSSeconds: Double
    let method: String
    let hardwareReadoutTimeKnown: Bool
}

enum ClockAligner {
    static func evidence(firstPTS: CMTime, callbackHostTime: Double) -> ClockEvidence {
        let pts = CMTimeGetSeconds(firstPTS)
        return ClockEvidence(firstVideoPTSSeconds: pts,
                             hostClockAtFirstCallbackSeconds: callbackHostTime,
                             callbackMinusPTSSeconds: callbackHostTime - pts,
                             method: "Video sample PTS compared with CMClock host time at callback; motion timestamps use CoreMotion sample timestamps. Offset is provisional until physical sync calibration.",
                             hardwareReadoutTimeKnown: false)
    }

    static func degreesPerSecond(_ radiansPerSecond: Double) -> Double {
        radiansPerSecond * 180.0 / .pi
    }
}
