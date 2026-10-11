import Foundation

/// Append a metadata track without remuxing or decoding existing media.
/// Existing chunk offsets and sample descriptions remain byte-for-byte intact.
enum MOVTelemetryMuxer {
    static func checkCopyCapacity(ordinary: Int64?, important: Int64?, required: Int64) throws {
        guard let available = [ordinary, important].compactMap({ $0 }).first(where: { $0 >= 0 }) else {
            throw RecorderError.unavailable("无法读取录制位置的剩余空间。原片和原始 IMU 已保留，请重新连接存储后重试。")
        }
        guard available >= required else {
            let need = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            let free = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            throw RecorderError.unavailable("内嵌元数据需在原视频所在磁盘临时复制视频：需要 \(need)，可用 \(free)。原片和原始 IMU 已保留。")
        }
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
    static func invalid() -> RecorderError { .unavailable("Invalid MOV atom structure; original retained") }
    static func box(_ type: String, _ payload: Data) -> Data {
        precondition(type.utf8.count == 4 && payload.count <= Int(UInt32.max) - 8)
        return Data.be(UInt64(payload.count + 8), 4) + Data(type.utf8) + payload
    }
    static func full(_ type: String, _ payload: Data) -> Data { box(type, Data(repeating: 0, count: 4) + payload) }
    static func words(_ values: UInt64...) -> Data { values.reduce(into: Data()) { $0 += Data.be($1, 4) } }

    static func append(to url: URL, kind: String, packets: [Data], durations: [UInt32], note: Data) throws {
        guard !packets.isEmpty, packets.count == durations.count, durations.allSatisfy({ $0 > 0 }),
              ["rtmd", "gyrf"].contains(kind), packets.allSatisfy({ $0.count <= Int(UInt32.max) }) else { throw invalid() }
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let length = try input.seekToEnd()
        var offset: UInt64 = 0, moovOffset: UInt64?, moov = Data()
        while offset < length {
            try input.seek(toOffset: offset)
            guard let header = try input.read(upToCount: 8), header.count == 8 else { throw invalid() }
            var size = header.uint(0, 4), headerSize = 8
            let type = String(decoding: header[4..<8], as: UTF8.self)
            if size == 1 {
                guard let extra = try input.read(upToCount: 8), extra.count == 8 else { throw invalid() }
                size = extra.uint(0, 8); headerSize = 16
            }
            if size == 0 { throw RecorderError.unavailable("Unbounded MOV atom cannot accept metadata") }
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
        var updated = Data()
        for child in children {
            updated += child.type == "mvhd" ? mv : Data(moov[child.offset..<(child.offset + child.size)])
        }
        updated += box("udta", note) + track
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".telemetry-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let volume = try url.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey
        ])
        // Read the same volume where the sibling temporary file will be created.
        // Important-usage capacity can be zero on external disks with ample free space.
        try checkCopyCapacity(ordinary: volume.volumeAvailableCapacity.map(Int64.init),
            important: volume.volumeAvailableCapacityForImportantUsage,
            required: Int64(length + payloadLength + UInt64(updated.count) + 64_000_000))
        try FileManager.default.copyItem(at: url, to: temporary)
        let output = try FileHandle(forWritingTo: temporary)
        do {
            try output.seek(toOffset: moovOffset + 4); try output.write(contentsOf: Data("free".utf8))
            try output.seekToEnd()
            try output.write(contentsOf: words(1) + Data("mdat".utf8) + Data.be(payloadLength + 16, 8))
            for packet in packets { try output.write(contentsOf: packet) }
            try output.write(contentsOf: box("moov", updated))
            try output.synchronize(); try output.close()
        } catch { try? output.close(); throw error }
        // Verify before replacing the source. No video re-encoding occurs here.
        let original = try RecordingFinalizer.inspectVideo(url)
        let embedded = try RecordingFinalizer.inspectVideo(temporary)
        guard original.codecFourCC == embedded.codecFourCC, original.width == embedded.width,
              original.height == embedded.height, original.frames.map(\.pts) == embedded.frames.map(\.pts) else { throw invalid() }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
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
