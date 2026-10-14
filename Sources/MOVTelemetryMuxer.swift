import Foundation
import AVFoundation
import Darwin
import CryptoKit

/// Append a metadata track without remuxing or decoding existing media.
/// Existing chunk offsets and sample descriptions remain byte-for-byte intact.
enum MOVTelemetryMuxer {
    static func captureVolumeCapacity(reported: Int64?, externalDevice: Int64?) -> Int64? {
        if let reported, reported > 0 { return reported }
        if let externalDevice, externalDevice > 0 { return externalDevice }
        return nil
    }
    static func checkCopyCapacity(ordinary: Int64?, important: Int64?, required: Int64) throws {
        guard let available = [ordinary, important].compactMap({ $0 }).first(where: { $0 >= 0 }) else {
            throw RecorderError.unavailable("无法读取录制位置的剩余空间。原片和原始 IMU 已保留，请重新连接存储后重试。")
        }
        guard available >= required else {
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            throw RecorderError.unavailable("内嵌元数据需在原视频所在磁盘追加运动元数据：需要 \(need)，可用 \(free)。原片和原始 IMU 已保留。")
        }
    }
    /// Foundation may reject its synchronization operation on an external filesystem.
    /// Fall back only for an unsupported operation; POSIX fsync must still succeed.
    static func synchronize(_ file: FileHandle) throws {
        try synchronize(primary: { try file.synchronize() }, fallback: {
            if Darwin.fsync(file.fileDescriptor) == 0 { return 0 }
            return errno
        })
    }

    static func synchronize(primary: () throws -> Void, fallback: () -> Int32) throws {
        do { try primary(); return }
        catch {
            let original = error
            var current: NSError? = error as NSError
            var unsupported = false
            for _ in 0..<8 {
                guard let value = current else { break }
                if value.domain == NSPOSIXErrorDomain,
                   [Int(EINVAL), Int(ENOTSUP), Int(ENOSYS)].contains(value.code) {
                    unsupported = true
                }
                current = value.userInfo[NSUnderlyingErrorKey] as? NSError
            }
            guard unsupported else { throw original }
            var result: Int32
            repeat { result = fallback() } while result == EINTR
            guard result == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(result), userInfo: [
                    NSLocalizedDescriptionKey: "POSIX fsync failed: \(String(cString: strerror(result)))",
                    NSUnderlyingErrorKey: original
                ])
            }
            NSLog("GyroCine MOV sync: Foundation unsupported; POSIX fsync succeeded")
        }
    }
    struct Recovery: Codable {
        let originalLength: UInt64
        let moovOffset: UInt64
        let unboundedAtomOffset: UInt64?
        init(originalLength: UInt64, moovOffset: UInt64, unboundedAtomOffset: UInt64? = nil) {
            self.originalLength = originalLength
            self.moovOffset = moovOffset
            self.unboundedAtomOffset = unboundedAtomOffset
        }
    }
    /// A size-zero final mdat extends to EOF. It must be bounded before new atoms are appended.
    static func boundedFinalMdatSize(offset: UInt64, fileLength: UInt64) -> UInt32? {
        guard offset <= fileLength, fileLength - offset >= 8,
              fileLength - offset <= UInt32.max else { return nil }
        return UInt32(fileLength - offset)
    }
    static func recoveryURL(_ url: URL) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let privateDirectory = RecordingStoragePaths.diagnosticDirectory
        try? FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
        if url.path.hasPrefix(documents.path + "/") {
            return privateDirectory.appendingPathComponent(url.lastPathComponent)
                .appendingPathExtension("metadata-recovery.json")
        }
        // A generated SSD URL scopes the movie itself. Keep the crash journal
        // in the app container, where creating a sibling file is permitted.
        let key = SHA256.hash(data: Data(url.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return privateDirectory
            .appendingPathComponent("external-\(key).metadata-recovery.json")
    }
    static func recoverIfNeeded(_ url: URL) throws {
        let journal = recoveryURL(url)
        guard FileManager.default.fileExists(atPath: journal.path) else { return }
        let state = try JSONDecoder().decode(Recovery.self, from: Data(contentsOf: journal))
        let file = try FileHandle(forUpdating: url)
        defer { try? file.close() }
        guard state.originalLength >= 8, state.moovOffset <= state.originalLength - 8,
              state.unboundedAtomOffset.map({ $0 <= state.originalLength - 8 }) ?? true,
              try file.seekToEnd() >= state.originalLength else { throw invalid() }
        // Even a torn four-byte commit is repaired from the durable journal.
        try file.seek(toOffset: state.moovOffset + 4)
        try file.write(contentsOf: Data("moov".utf8))
        if let atomOffset = state.unboundedAtomOffset {
            try file.seek(toOffset: atomOffset)
            try file.write(contentsOf: Data(repeating: 0, count: 4))
        }
        try file.truncate(atOffset: state.originalLength)
        try synchronize(file)
        try FileManager.default.removeItem(at: journal)
    }
    static func hasTelemetry(_ url: URL) -> Bool {
        guard let file = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? file.close() }
        do {
            let end = try file.seekToEnd()
            var offset: UInt64 = 0
            while offset + 8 <= end {
                try file.seek(toOffset: offset)
                guard let header = try file.read(upToCount: 8), header.count == 8 else { return false }
                var size = header.uint(0, 4), headerSize: UInt64 = 8
                if size == 1 {
                    guard let extended = try file.read(upToCount: 8), extended.count == 8 else { return false }
                    size = extended.uint(0, 8); headerSize = 16
                }
                if size == 0 { size = end - offset }
                guard size >= headerSize, size <= end - offset else { return false }
                if String(decoding: header[4..<8], as: UTF8.self) == "moov" {
                    guard size - headerSize < 256_000_000,
                          let data = try file.read(upToCount: Int(size - headerSize)) else { return false }
                    for track in try atoms(data) where track.type == "trak" {
                        let bytes = Data(data[track.offset..<(track.offset + track.size)])
                        let marker = bytes.range(of: Data("Sony RTMD compatibility\0".utf8)) != nil
                            || bytes.range(of: Data("GyroflowProtobuf\0".utf8)) != nil
                        if marker {
                            if try telemetrySamplesArePresent(Data(bytes.dropFirst(track.header)), fileLength: end) { return true }
                        }
                    }
                }
                offset += size
            }
        } catch { return false }
        return false
    }
    private static func telemetrySamplesArePresent(_ track: Data, fileLength: UInt64) throws -> Bool {
        func child(_ data: Data, _ name: String) throws -> Data? {
            guard let atom = try atoms(data).first(where: { $0.type == name }) else { return nil }
            return Data(data[(atom.offset + atom.header)..<(atom.offset + atom.size)])
        }
        guard let mdia = try child(track, "mdia"), let minf = try child(mdia, "minf"),
              let stbl = try child(minf, "stbl"), let stsd = try child(stbl, "stsd"),
              stsd.count >= 16, stsd.uint(4, 4) == 1,
              ["rtmd", "gyrf"].contains(String(decoding: stsd[12..<16], as: UTF8.self)),
              let sizes = try child(stbl, "stsz"), sizes.count >= 12,
              let offsets = try child(stbl, "co64"), offsets.count >= 8 else { return false }
        let count = sizes.uint(8, 4), fixed = sizes.uint(4, 4)
        guard count > 0, offsets.uint(4, 4) == count,
              count <= UInt64((offsets.count - 8) / 8),
              fixed > 0 || count <= UInt64((sizes.count - 12) / 4) else { return false }
        for index in 0..<Int(count) {
            let offset = offsets.uint(8 + index * 8, 8)
            let size = fixed > 0 ? fixed : sizes.uint(12 + index * 4, 4)
            guard size > 0, offset <= fileLength, size <= fileLength - offset else { return false }
        }
        return true
    }

    struct Atom { let offset: Int; let size: Int; let header: Int; let type: String }
    static func atoms(_ data: Data) throws -> [Atom] {
        var result: [Atom] = [], offset = 0
        while offset < data.count {
            guard data.count - offset >= 8 else { throw invalid() }
            var size = Int(data.uint( offset, 4)), header = 8
            let type = String(decoding: data[(offset + 4)..<(offset + 8)], as: UTF8.self)
            if size == 1 {
                guard data.count - offset >= 16 else { throw invalid() }
                let large = data.uint(offset + 8, 8)
                guard large <= UInt64(Int.max) else { throw invalid() }
                size = Int(large); header = 16
            }
            if size == 0 { size = data.count - offset }
            guard size >= header, size <= data.count - offset else { throw invalid() }
            result.append(Atom(offset: offset, size: size, header: header, type: type)); offset += size
        }
        return result
    }
    static func isAVTrack(_ payload: Data) throws -> Bool {
        guard let mdia = try atoms(payload).first(where: { $0.type == "mdia" }) else { return false }
        let media = Data(payload[(mdia.offset + mdia.header)..<(mdia.offset + mdia.size)])
        guard let handler = try atoms(media).first(where: { $0.type == "hdlr" }),
              handler.size >= handler.header + 12 else { return false }
        let start = handler.offset + handler.header + 8
        let type = String(decoding: media[start..<(start + 4)], as: UTF8.self)
        return type == "vide" || type == "soun"
    }
    static func invalid() -> RecorderError { .unavailable("Invalid MOV atom structure; original retained") }
    static func box(_ type: String, _ payload: Data) -> Data {
        precondition(type.utf8.count == 4 && payload.count <= Int(UInt32.max) - 8)
        return Data.be(UInt64(payload.count + 8), 4) + Data(type.utf8) + payload
    }
    static func full(_ type: String, _ payload: Data) -> Data { box(type, Data(repeating: 0, count: 4) + payload) }
    static func words(_ values: UInt64...) -> Data { values.reduce(into: Data()) { $0 += Data.be($1, 4) } }

    static func append(to url: URL, kind: String, packets: [Data], durations: [UInt32], note: Data) throws {
        var stage = "检查 MOV"
        do {
            try appendChecked(to: url, kind: kind, packets: packets, durations: durations, note: note, stage: &stage)
        } catch {
            throw RecorderError.unavailable("MOV 元数据写入失败（\(stage)）：\(errorChain(error))")
        }
    }

    static func errorChain(_ error: Error) -> String {
        var current: NSError? = error as NSError
        var parts: [String] = []
        for _ in 0..<8 {
            guard let value = current else { break }
            parts.append("\(value.domain):\(value.code) \(value.localizedDescription)")
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " → ")
    }

    private static func appendChecked(to url: URL, kind: String, packets: [Data], durations: [UInt32], note: Data, stage: inout String) throws {
        guard !packets.isEmpty, packets.count == durations.count, durations.allSatisfy({ $0 > 0 }),
              ["rtmd", "gyrf"].contains(kind), packets.allSatisfy({ $0.count <= Int(UInt32.max) }) else { throw invalid() }
        try recoverIfNeeded(url)
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        var offset: UInt64 = 0, moovOffset: UInt64?, unboundedMdatOffset: UInt64?, moov = Data()
        while offset < length {
            try input.seek(toOffset: offset)
            guard let header = try input.read(upToCount: 8), header.count == 8 else { throw invalid() }
            var size = header.uint(0, 4), headerSize = 8
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1 {
                guard let extra = try input.read(upToCount: 8), extra.count == 8 else { throw invalid() }
                size = extra.uint(0, 8); headerSize = 16
            }
            if size == 0 {
                guard type == "mdat", unboundedMdatOffset == nil,
                      let bounded = boundedFinalMdatSize(offset: offset, fileLength: length) else {
                    throw RecorderError.unavailable("Unbounded MOV atom \(type) at \(offset) cannot accept metadata")
                }
                unboundedMdatOffset = offset
                size = UInt64(bounded)
            }
            guard size >= headerSize, size <= length - offset else { throw invalid() }
            if type == "moov" {
                guard moovOffset == nil, size < 256_000_000,
                      let payload = try input.read(upToCount: Int(size) - headerSize), payload.count == Int(size) - headerSize else { throw invalid() }
                moovOffset = offset; moov = payload
            }
            offset += size
        }
        guard let moovOffset else { throw invalid() }
        let children = try atoms(moov)
        guard let mvAtom = children.first(where: { $0.type == "mvhd" }) else { throw invalid() }
        var mv = Data(moov[mvAtom.offset..<(mvAtom.offset + mvAtom.size)])
        let scaleOffset = mvAtom.header + (mv[mvAtom.header] == 1 ? 20 : 12)
        guard mv.count >= scaleOffset + 4 else { throw invalid() }
        let scale = mv.uint(scaleOffset, 4), trackID = mv.uint(mv.count - 4, 4)
        guard scale > 0, trackID > 0, trackID < UInt32.max else { throw invalid() }
        mv.replaceSubrange((mv.count - 4)..<mv.count, with: Data.be(trackID + 1, 4))
        let totalTicks = durations.reduce(UInt64(0)) { $0 + UInt64($1) }
        let movieDuration = UInt64((Double(totalTicks) / 1_000_000 * Double(scale)).rounded())
        let matrix = words(65536, 0, 0, 0, 65536, 0, 0, 0, 1073741824)
        // version 1 duration fields support clips longer than 4294 seconds.
        let tk = box("tkhd", Data([1, 0, 0, 3]) + Data(repeating: 0, count: 16) + words(trackID, 0)
            + Data.be(movieDuration, 8) + Data(repeating: 0, count: 16) + matrix + words(0, 0))
        let md = box("mdhd", Data([1, 0, 0, 0]) + Data(repeating: 0, count: 16) + words(1_000_000)
            + Data.be(totalTicks, 8) + Data([0x55, 0xc4, 0, 0]))
        let handler = kind == "rtmd" ? "Sony RTMD compatibility" : "GyroflowProtobuf"
        let hd = full("hdlr", words(0) + Data("meta".utf8) + Data(repeating: 0, count: 12) + Data((handler + "\0").utf8))
        let entry = box(kind, Data(repeating: 0, count: 6) + Data([0, 1]))
        var runs: [(UInt32, UInt32)] = []
        for duration in durations {
            if let last = runs.last, last.1 == duration { runs[runs.count - 1].0 += 1 }
            else { runs.append((1, duration)) }
        }
        let stts = full("stts", words(UInt64(runs.count)) + runs.reduce(into: Data()) { $0 += words(UInt64($1.0), UInt64($1.1)) })
        let payloadLength = packets.reduce(UInt64(0)) { $0 + UInt64($1.count) }
        // Extended-size mdat avoids a 4 GB metadata limitation.
        var chunkOffset = length + 16
        var offsets = Data()
        for packet in packets { offsets += Data.be(chunkOffset, 8); chunkOffset += UInt64(packet.count) }
        let table = full("stsd", words(1) + entry) + stts + full("stsc", words(1, 1, 1, 1))
            + full("stsz", words(0, UInt64(packets.count)) + packets.reduce(into: Data()) { $0 += Data.be(UInt64($1.count), 4) })
            + full("co64", words(UInt64(packets.count)) + offsets)
        let dinf = box("dinf", full("dref", words(1) + box("url ", Data([0, 0, 0, 1]))))
        let track = box("trak", tk + box("mdia", md + hd + box("minf", full("nmhd", Data()) + dinf + box("stbl", table))))
        // The parser must see the video's rotation before our first metadata track.
        var updated = Data(), deferredTracks = Data()
        for child in children {
            let bytes = Data(moov[child.offset..<(child.offset + child.size)])
            if child.type == "trak", try !isAVTrack(Data(bytes.dropFirst(child.header))) {
                deferredTracks += bytes
            } else {
                updated += child.type == "mvhd" ? mv : bytes
            }
        }
        updated += track + deferredTracks
        updated += box("udta", note)
        stage = "读取磁盘容量"
        let volume = try? url.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityKey
        ])
        let reported = volume?.volumeAvailableCapacity.map(Int64.init)
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let external = !url.path.hasPrefix(documents.path + "/")
        let selectedID = UserDefaults.standard.string(forKey: "externalDeviceID")
        let deviceFree = external ? AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices
            .first(where: { $0.isConnected && $0.uuid?.uuidString == selectedID })?.freeSize : nil
        let available = captureVolumeCapacity(reported: reported, externalDevice: deviceFree.map(Int64.init))
        try checkCopyCapacity(ordinary: available,
            important: nil,
            required: Int64(payloadLength + UInt64(updated.count) + 64_000_000))
        let recovery = Recovery(originalLength: length, moovOffset: moovOffset,
                                unboundedAtomOffset: unboundedMdatOffset)
        let journal = recoveryURL(url)
        stage = "创建恢复日志"
        try JSONEncoder().encode(recovery).write(to: journal, options: .atomic)
        let journalHandle = try FileHandle(forWritingTo: journal)
        stage = "同步恢复日志到磁盘"
        defer { try? journalHandle.close() }
        try synchronize(journalHandle); try journalHandle.close()
        stage = "以读写方式打开 MOV"
        let output = try FileHandle(forUpdating: url)
        do {
            // Original moov stays valid until all added data is durable and verified.
            if let unboundedMdatOffset,
               let bounded = boundedFinalMdatSize(offset: unboundedMdatOffset, fileLength: length) {
                stage = "限定原始 mdat 长度"
                try output.seek(toOffset: unboundedMdatOffset)
                try output.write(contentsOf: Data.be(UInt64(bounded), 4))
                try synchronize(output)
            }
            stage = "追加元数据"
            try output.seek(toOffset: length)
            try output.write(contentsOf: words(1) + Data("mdat".utf8) + Data.be(payloadLength + 16, 8))
            for packet in packets { try output.write(contentsOf: packet) }
            let newMoov = box("moov", updated)
            try output.write(contentsOf: newMoov)
            stage = "同步追加内容到磁盘"
            try synchronize(output)
            stage = "读回验证追加内容"
            guard try output.seekToEnd() == length + 16 + payloadLength + UInt64(newMoov.count) else { throw invalid() }
            try output.seek(toOffset: length + 16 + payloadLength)
            guard try output.read(upToCount: newMoov.count) == newMoov else { throw invalid() }
            // Commit only the old atom's four-byte type; encoded video/audio are untouched.
            stage = "提交 MOV 索引"
            try output.seek(toOffset: moovOffset + 4)
            try output.write(contentsOf: Data("free".utf8))
            stage = "同步 MOV 索引到磁盘"
            try synchronize(output); try output.close()
            stage = "移除恢复日志"
            try FileManager.default.removeItem(at: journal)
        } catch {
            try? output.close()
            let original = error
            do { try recoverIfNeeded(url) }
            catch {
                throw RecorderError.unavailable("原错误：\(errorChain(original))；恢复未完成：\(errorChain(error))。请保留 MOV 和恢复日志。")
            }
            throw original
        }

    }
}

extension Data {
    static func be(_ value: UInt64, _ bytes: Int) -> Data {
        Data((0..<bytes).map { UInt8(truncatingIfNeeded: value >> ((bytes - 1 - $0) * 8)) })
    }
    func uint(_ offset: Int, _ bytes: Int) -> UInt64 {
        self[offset..<(offset + bytes)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}
