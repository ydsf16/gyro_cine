import Foundation
import QuartzCore

enum RecordingStoragePaths {
    private static var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var movieDirectory: URL {
        documents.appendingPathComponent("Media", isDirectory: true)
    }

    static var diagnosticDirectory: URL {
        documents.appendingPathComponent("Log", isDirectory: true)
    }

    static var legacyDirectory: URL {
        documents.appendingPathComponent("Sessions", isDirectory: true)
    }

    /// Split old Sessions content without changing file names or recovery jobs.
    static func prepare() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: movieDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: diagnosticDirectory, withIntermediateDirectories: true)
        try migrateSessions(from: legacyDirectory, moviesTo: movieDirectory, diagnosticsTo: diagnosticDirectory)
        let privateSessions = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sessions", isDirectory: true)
        try migrateSessions(from: privateSessions, moviesTo: movieDirectory, diagnosticsTo: diagnosticDirectory)
    }

    static func migrateSessions(from oldDirectory: URL, moviesTo movieDirectory: URL,
                                diagnosticsTo diagnosticDirectory: URL) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: oldDirectory.path) else { return }
        try manager.createDirectory(at: movieDirectory, withIntermediateDirectories: true)
        try manager.createDirectory(at: diagnosticDirectory, withIntermediateDirectories: true)
        let files = try manager.contentsOfDirectory(at: oldDirectory, includingPropertiesForKeys: nil)
        for file in files.sorted(by: { ($0.lastPathComponent.hasSuffix(".pending-imu.json") ? 1 : 0) <
            ($1.lastPathComponent.hasSuffix(".pending-imu.json") ? 1 : 0) }) {
            let destinationDirectory = file.pathExtension.lowercased() == "mov" ? movieDirectory : diagnosticDirectory
            let destination = destinationDirectory.appendingPathComponent(file.lastPathComponent)
            guard !manager.fileExists(atPath: destination.path) else { continue }
            try manager.moveItem(at: file, to: destination)
        }
        if try manager.contentsOfDirectory(atPath: oldDirectory.path).isEmpty {
            try manager.removeItem(at: oldDirectory)
        }
    }
}

final class DiagnosticLogger {
    let sessionID = UUID().uuidString
    let sessionURL: URL
    let capabilityURL: URL
    private let queue = DispatchQueue(label: "RAWFocusTest.logger")
    private let encoder = JSONSerialization.self
    private var sessionHandle: FileHandle?

    init() {
        let directory = RecordingStoragePaths.diagnosticDirectory
        sessionURL = directory.appendingPathComponent("focus-\(sessionID).jsonl")
        capabilityURL = directory.appendingPathComponent("capabilities-\(sessionID).json")
        // Queued before every subsequent log write; migration never blocks SwiftUI init.
        queue.async {
            do { try RecordingStoragePaths.prepare() }
            catch { NSLog("GyroCine diagnostic migration: %@", String(describing: error)) }
            FileManager.default.createFile(atPath: self.sessionURL.path, contents: nil)
            self.sessionHandle = try? FileHandle(forWritingTo: self.sessionURL)
        }
    }

    func event(_ type: String, _ data: [String: Any] = [:]) {
        if type == "focus_sample" && !UserDefaults.standard.bool(forKey: "debugEnabled") { return }
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
            try? sessionHandle?.write(contentsOf: Data(output.utf8))
        }
    }

    func capabilityReport(_ report: [String: Any]) {
        queue.async { [self] in
            guard JSONSerialization.isValidJSONObject(report),
                  let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) else { return }
            try? data.write(to: capabilityURL, options: .atomic)
        }
    }

    func whenReady(_ completion: @escaping () -> Void) { queue.async(execute: completion) }

    func flush(_ completion: @escaping () -> Void) {
        queue.async { [self] in
            try? sessionHandle?.synchronize()
            DispatchQueue.main.async(execute: completion)
        }
    }
}
