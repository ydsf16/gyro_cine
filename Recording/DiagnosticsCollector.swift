import Foundation
import OSLog

enum DiagnosticsCollector {
    private static let logger = Logger(subsystem: "com.tinygrape.RawMotionRecorder", category: "Recording")

    static func record(_ message: String, folder: URL?) {
        logger.info("\(message, privacy: .public)")
        guard let folder else { return }
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = folder.appendingPathComponent("events.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
            try? handle.close()
        }
    }
}
