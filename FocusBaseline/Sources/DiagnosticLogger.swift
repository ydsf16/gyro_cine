import Foundation
import QuartzCore

final class DiagnosticLogger {
    let sessionID = UUID().uuidString
    let sessionURL: URL
    let capabilityURL: URL
    private let queue = DispatchQueue(label: "RAWFocusTest.logger")
    private let encoder = JSONSerialization.self
    private var sessionHandle: FileHandle?

    init() {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = root.appendingPathComponent("Sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        sessionURL = directory.appendingPathComponent("focus-\(sessionID).jsonl")
        capabilityURL = directory.appendingPathComponent("capabilities-\(sessionID).json")
        FileManager.default.createFile(atPath: sessionURL.path, contents: nil)
        sessionHandle = try? FileHandle(forWritingTo: sessionURL)
    }

    func event(_ type: String, _ data: [String: Any] = [:]) {
        let instant = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        let row: [String: Any] = ["sessionID": sessionID, "wallTime": ISO8601DateFormatter().string(from: instant),
                                  "monotonicSeconds": uptime, "eventType": type, "data": data]
        queue.async { [self] in
            guard JSONSerialization.isValidJSONObject(row),
                  let bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]),
                  let line = String(data: bytes, encoding: .utf8) else { return }
            let output = line + "\n"
            print("RAWFocusTest \(output)", terminator: "")
            sessionHandle?.write(Data(output.utf8))
        }
    }

    func capabilityReport(_ report: [String: Any]) {
        queue.async { [self] in
            guard JSONSerialization.isValidJSONObject(report),
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: capabilityURL, options: .atomic)
        }
    }

    func flush(_ completion: @escaping () -> Void) {
        queue.async { [self] in
            sessionHandle?.synchronizeFile()
            DispatchQueue.main.async(execute: completion)
        }
    }
}
