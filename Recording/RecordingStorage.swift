import Foundation
import AVFoundation

enum RecordingStorage: String, CaseIterable, Identifiable {
    case files
    case ssd

    var id: String { rawValue }
    var label: String { self == .files ? "文件" : "SSD" }

    static let appFolderName = "RawMotionRecorder"
    /// External volumes need their device/ordinary capacity, not iOS purgeable-space accounting.
    static func availableBytes(location: RecordingStorage, external: Int64?, ordinary: Int64?, important: Int64?) -> Int64? {
        let candidates = location == .ssd ? [external, ordinary, important] : [important, ordinary]
        return candidates.compactMap { $0 }.first { $0 >= 0 }
    }
    static var filesRoot: URL {
        // iOS exposes this Documents directory as “On My iPhone / GyroCine”.
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static func ssdRoot(in parent: URL) -> URL {
        parent.lastPathComponent.caseInsensitiveCompare("DCIM") == .orderedSame
            ? parent : parent.appendingPathComponent("DCIM", isDirectory: true)
    }

    static func createSSDRoot(in parent: URL) throws -> URL {
        let root = ssdRoot(in: parent)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

/// Keep small telemetry writes off external storage during real-time capture.
/// Failed publication leaves the local log intact for recovery.
final class StagedRecordingLog {
    private let localURL: URL
    private let destination: URL
    private var handle: FileHandle?
    init(destination: URL) throws {
        self.destination = destination
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PendingTelemetry", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        localURL = root.appendingPathComponent(UUID().uuidString + "-" + destination.lastPathComponent)
        guard FileManager.default.createFile(atPath: localURL.path, contents: nil) else {
            throw RecorderError.unavailable("Cannot create local telemetry log")
        }
        handle = try FileHandle(forWritingTo: localURL)
    }
    func write(contentsOf data: Data) throws {
        guard let handle else { throw RecorderError.unavailable("Telemetry log is closed") }
        try handle.write(contentsOf: data)
    }
    func close() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }
    func publish() throws {
        try close()
        do {
            try FileManager.default.copyItem(at: localURL, to: destination)
        } catch {
            throw RecorderError.unavailable("日志归档失败，本地日志已保留：\(localURL.path)。\(error.localizedDescription)")
        }
        try? FileManager.default.removeItem(at: localURL)
    }
    deinit { try? handle?.close() }
}

extension URL {
    var recordingBaseName: String { (lastPathComponent.hasPrefix("GyroCine_") || lastPathComponent.hasPrefix("SteadyCine_")) ? lastPathComponent : "clip" }
    func recordingFile(_ suffix: String) -> URL { appendingPathComponent(recordingBaseName + "." + suffix) }
}

/// Public iOS 27 selectors, runtime-gated while building with the iOS 26 SDK.
/// Never infer support from a model name or OS version alone.
enum RAWInternalStorage {
    static func enableProStorageIfSupported(on writer: AVAssetWriter) -> Bool {
        let supported = NSSelectorFromString("isProVideoStorageSupported")
        let alternate = NSSelectorFromString("proVideoStorageSupported")
        let setter = NSSelectorFromString("setUsesProVideoStorage:")
        guard writer.responds(to: supported) || writer.responds(to: alternate),
              writer.responds(to: setter),
              (writer.value(forKey: "proVideoStorageSupported") as? NSNumber)?.boolValue == true else { return false }
        writer.setValue(true, forKey: "usesProVideoStorage")
        return (writer.value(forKey: "usesProVideoStorage") as? NSNumber)?.boolValue == true
    }
}
