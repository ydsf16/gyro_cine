import Foundation

enum RecordingState: String {
    case idle, configuring, ready, recording, finalizing, completed, failed
}

enum RecorderError: LocalizedError {
    case cameraPermission
    case microphonePermission
    case noCamera
    case unsupported4K30
    case noHEVC
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .cameraPermission: "Camera permission is required. Enable it in Settings."
        case .microphonePermission: "Microphone permission is required while audio is on."
        case .noCamera: "Back wide camera was not found."
        case .unsupported4K30: "This camera has no 4K/30 format. No fallback was applied."
        case .noHEVC: "HEVC is not available for the selected camera format."
        case .unavailable(let reason): reason
        }
    }
}
