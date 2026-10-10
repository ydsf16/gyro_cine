import Foundation
import Darwin

enum RecorderIdentity {
    static var hardwareModel: String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 0 else { return "Unknown iPhone" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &bytes, &size, nil, 0) == 0 else { return "Unknown iPhone" }
        return String(cString: bytes)
    }
    static var cameraModel: String {
        let id = hardwareModel
        return id == "iPhone17,3" ? "iPhone 16 (iPhone17,3)" : id
    }
}
