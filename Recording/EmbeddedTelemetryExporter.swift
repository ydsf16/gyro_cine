import Foundation

/// Shared clock/exposure mapping for all three output modes.
enum EmbeddedTelemetryExporter {
    struct Sample { let time: Double; let gyro: [Double]; let accel: [Double] }
    static func write(mode: RecordingOutputMode, folder: URL, video: ActualVideoInfo,
                      events: [MotionEvent], evidence: [CaptureFrameEvidence], diagnostics: RecordingDiagnostics,
                      sourceFirstPTS: Double, fps: Double) throws {
        guard mode != .gcsv, evidence.count == video.frames.count, let first = video.frames.first,
              let last = video.frames.last, fps.isFinite, fps > 0 else { throw MOVTelemetryMuxer.invalid() }
        let duration = last.pts - first.pts + 1 / fps
        let exposure = try ExposureTimingCompensation(exposures: evidence.compactMap(\.deviceExposureDurationAtCallbackSeconds))
        let map: (Double) -> Double = {
            (diagnostics.recordedClockMap?.videoSeconds(for: $0) ?? ($0 - sourceFirstPTS + first.pts))
                + exposure.correctionSeconds - first.pts
        }
        let gyro = events.filter { $0.kind == .gyro }.map { MappedGyroSample(time: map($0.timestamp), x: $0.x, y: $0.y, z: $0.z) }
        let accel = events.filter { $0.kind == .accel }.map { MappedGyroSample(time: map($0.timestamp), x: $0.x, y: $0.y, z: $0.z) }
        // Independent gyro/accel timestamp streams; never assume callbacks have identical timestamps.
        func validate(_ values: [MappedGyroSample]) throws {
            guard values.count >= 2, values.allSatisfy({ [$0.time, $0.x, $0.y, $0.z].allSatisfy(\.isFinite) }),
                  zip(values, values.dropFirst()).allSatisfy({ $0.time < $1.time }),
                  values[0].time <= 0, values.last!.time >= duration else {
                throw RecorderError.unavailable("Embedded IMU does not cover video boundaries; original retained")
            }
        }
        try validate(gyro); try validate(accel)
        func interpolate(_ values: [MappedGyroSample], at time: Double) throws -> [Double] {
            var low = 0, high = values.count - 1
            while low + 1 < high { let mid = (low + high) / 2; if values[mid].time <= time { low = mid } else { high = mid } }
            let a = values[low], b = values[high], gap = b.time - a.time
            guard gap > 0, gap <= GyroTimeline.maximumInterpolationGapSeconds else {
                throw RecorderError.unavailable("Embedded IMU interpolation gap exceeds 30ms")
            }
            let fraction = (time - a.time) / gap
            return [a.x + (b.x - a.x) * fraction, a.y + (b.y - a.y) * fraction, a.z + (b.z - a.z) * fraction]
        }
        let profile = try Data(contentsOf: folder.appendingPathComponent("lens_profile.json"))
        let profileObject = try JSONSerialization.jsonObject(with: profile) as! [String: Any]
        let params = profileObject["fisheye_params"] as! [String: Any]
        let matrix = (params["camera_matrix"] as! [[Double]]).flatMap { $0 }
        var noteObject: [String: Any] = ["source_camera": diagnostics.deviceModel,
            "transport": mode.rawValue, "experimental": true, "original_lens_profile": profileObject,
            "hardware_readout_time_known": false, "pixel_pitch_known": false,
            "exposure_correction_ms": exposure.correctionSeconds * 1000,
            "acceleration_export_convention": "negative CoreMotion XYZ; raw log unchanged",
            "timing": "Empirical positive mean half exposure; PTS-based estimate; optical sync unverified",
            "raw_color_export": "Gyroflow RAW export color conversion unverified"]
        if mode == .sonyMOV {
            noteObject["virtual_sensor_geometry"] = true
            noteObject["principal_point_approximation"] = "image center"
            noteObject["focal_length_mm_is_physical"] = false
        }
        let note = try JSONSerialization.data(withJSONObject: noteObject, options: [.sortedKeys])
        var packets: [Data] = [], durations: [UInt32] = []
        if mode == .sonyMOV {
            let count = max(1, Int(ceil(duration * 100)))
            for index in 0..<count {
                let time = Double(index) * duration / Double(count)
                let sample = Sample(time: time, gyro: try interpolate(gyro, at: time), accel: try interpolate(accel, at: time))
                packets.append(try sonyPacket(sample, matrix: matrix, width: video.width, height: video.height))
                let ticks = Int64((Double(index + 1) * duration / Double(count) * 1e6).rounded())
                    - Int64((time * 1e6).rounded())
                guard ticks > 0, ticks <= UInt32.max else { throw MOVTelemetryMuxer.invalid() }
                durations.append(UInt32(ticks))
            }
        } else {
            // Retain native gyro cadence, interpolate accelerometer only at gyro timestamps.
            var samples = [Sample(time: 0, gyro: try interpolate(gyro, at: 0), accel: try interpolate(accel, at: 0))]
            for value in gyro where value.time > 0 && value.time < duration {
                samples.append(Sample(time: value.time, gyro: [value.x, value.y, value.z], accel: try interpolate(accel, at: value.time)))
            }
            samples.append(Sample(time: duration, gyro: try interpolate(gyro, at: duration), accel: try interpolate(accel, at: duration)))
            var cursor = 0
            for (index, frame) in video.frames.enumerated() {
                let start = frame.pts - first.pts
                let end = index + 1 < video.frames.count ? video.frames[index + 1].pts - first.pts : duration
                var imu: [Sample] = []
                while cursor < samples.count && (samples[cursor].time < end || index == video.frames.count - 1) {
                    imu.append(samples[cursor]); cursor += 1
                }
                packets.append(try protobufPacket(index: index, pts: start, evidence: evidence[index], samples: imu,
                    header: index == 0 ? protobufHeader(video: video, fps: fps, camera: diagnostics.deviceModel,
                        lens: diagnostics.selectedLens?.name ?? "Fixed physical lens", profile: profile, note: note) : nil))
                let ticks = Int64((end * 1e6).rounded()) - Int64((start * 1e6).rounded())
                guard ticks > 0, ticks <= UInt32.max else { throw MOVTelemetryMuxer.invalid() }
                durations.append(UInt32(ticks))
            }
        }
        var atoms = MOVTelemetryMuxer.box("rmin", note)
        if mode == .sonyMOV {
            let xml = "<Compatibility manufacturer=\"Sony\" modelName=\"RawMotion \(diagnostics.deviceModel) compatibility\"><Lens modelName=\"Apple API K approximation\"/></Compatibility>"
            atoms += MOVTelemetryMuxer.box("xml ", Data(xml.utf8))
        }
        try MOVTelemetryMuxer.append(to: folder.appendingPathComponent("clip.mov"), kind: mode == .sonyMOV ? "rtmd" : "gyrf",
                                     packets: packets, durations: durations, note: atoms)
        try note.write(to: folder.appendingPathComponent("embedded_metadata.json"), options: .atomic)
    }

    static func sonyPacket(_ sample: Sample, matrix: [Double], width: Int, height: Int) throws -> Data {
        guard matrix.count == 9, width > 0, height > 0, width * 10 <= UInt16.max, height * 10 <= UInt16.max else { throw MOVTelemetryMuxer.invalid() }
        func tag(_ id: UInt64, _ data: Data) -> Data { Data.be(id, 2) + Data.be(UInt64(data.count), 2) + data }
        // Virtual unit conversion for Sony's lens fallback. Never claim this is measured sensor geometry.
        var p = tag(0xe405, Data.be(UInt64(width), 2) + Data.be(UInt64(height), 2))
        p += tag(0xe407, Data.be(10000, 2) + Data.be(10000, 2))
        p += tag(0xe40a, Data.be(UInt64(width), 4) + Data.be(UInt64(height), 4))
        p += tag(0x8104, Data.be(UInt64(width * 10), 2)) + tag(0x8105, Data.be(UInt64(height * 10), 2))
        let focal = matrix[0] * 10000
        guard focal.isFinite, focal > 0, focal <= Double(UInt32.max) else { throw MOVTelemetryMuxer.invalid() }
        p += tag(0xe421, Data.be(UInt64(focal.rounded()), 4) + Data.be(0, 4) + Data([0]) + Data.be(UInt64(Float(1).bitPattern), 4) + Data.be(0, 4) + Data.be(2, 4))
        p += tag(0xe420, Data([0]))
        for (start, values, scale) in [(UInt64(0xe435), sample.gyro.map { $0 * 180 / .pi }, Float(100)),
                                        (UInt64(0xe445), sample.accel.map { ClockAligner.exportedAcceleration($0) / 9.80665 }, Float(1000))] {
            var vector = Data()
            for value in values {
                let integer = (value * Double(scale)).rounded()
                guard integer.isFinite, integer >= Double(Int16.min), integer <= Double(Int16.max) else {
                    throw RecorderError.unavailable("Sony metadata range exceeded; original retained")
                }
                vector += Data.be(UInt64(UInt16(bitPattern: Int16(integer))), 2)
            }
            p += tag(start, Data.be(100, 4)) + tag(start + 4, Data.be(UInt64(scale.bitPattern), 4))
                + tag(start + 5, Data.be(0x502, 2)) + tag(start + 6, Data.be(1, 4) + Data.be(6, 4) + vector)
        }
        return Data([0, 0x1c]) + Data(repeating: 0, count: 26) + p
    }

    static func protobufHeader(video: ActualVideoInfo, fps: Double, camera: String, lens: String, profile: Data, note: Data) -> Data {
        var c = ProtoWire.string(1, "Apple") + ProtoWire.string(2, camera) + ProtoWire.string(5, "Apple")
        c += ProtoWire.string(6, lens) + ProtoWire.bytes(12, profile) + ProtoWire.string(13, "XYZ") + ProtoWire.bytes(16, note)
        // Unknown sensor size/pixel pitch/readout fields are omitted, never fabricated.
        var clip = ProtoWire.integer(1, UInt64(video.width)) + ProtoWire.integer(2, UInt64(video.height))
        clip += ProtoWire.double(3, video.duration * 1e6) + ProtoWire.float(4, Float(fps))
            + ProtoWire.float(5, Float(fps)) + ProtoWire.float(6, Float(fps))
            + ProtoWire.integer(8, 100) + ProtoWire.float(10, 1)
        return ProtoWire.bytes(1, c) + ProtoWire.bytes(2, clip)
    }

    static func protobufPacket(index: Int, pts: Double, evidence: CaptureFrameEvidence, samples: [Sample], header: Data?) throws -> Data {
        guard let matrix = evidence.cameraIntrinsicMatrix, matrix.count == 9,
              let exposure = evidence.deviceExposureDurationAtCallbackSeconds, exposure.isFinite, exposure > 0,
              matrix.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw MOVTelemetryMuxer.invalid() }
        // Schema uses readout-latch time. Model an estimated latch so midpoint equals MOV PTS.
        // This is an estimate, explicitly disclosed in header.additional_data; rolling shutter remains unknown.
        let latch = (pts + exposure / 2) * 1e6
        var frame = ProtoWire.double(1, latch) + ProtoWire.double(2, latch) + ProtoWire.integer(3, UInt64(index + 1))
            + ProtoWire.double(5, exposure * 1e6)
        if let iso = evidence.deviceISOAtCallback, iso.isFinite, iso > 0, Double(iso) <= Double(UInt32.max) {
            frame += ProtoWire.integer(4, UInt64(iso.rounded()))
        }
        var packed = Data()
        for value in matrix { packed += ProtoWire.little(UInt64(Float(value).bitPattern), 4) }
        frame += ProtoWire.bytes(16, ProtoWire.bytes(1, packed))
        for sample in samples {
            var imu = ProtoWire.double(1, sample.time * 1e6)
            let values = sample.gyro.map { $0 * 180 / .pi } + sample.accel.map(ClockAligner.exportedAcceleration)
            guard values.allSatisfy({ $0.isFinite && Float($0).isFinite }) else { throw MOVTelemetryMuxer.invalid() }
            for (i, value) in values.enumerated() { imu += ProtoWire.float(i + 2, Float(value)) }
            frame += ProtoWire.bytes(17, imu)
        }
        var main = ProtoWire.string(1, "GyroflowProtobuf") + ProtoWire.integer(2, 1)
        if let header { main += ProtoWire.bytes(3, header) }
        return main + ProtoWire.bytes(4, frame)
    }
}

/// Minimal protobuf wire writer for the pinned official gyroflow.proto fields used above.
/// Field numbers/types are checked against the generated official decoder in acceptance tests.
enum ProtoWire {
    static func varint(_ input: UInt64) -> Data {
        var value = input, data = Data()
        while value >= 128 { data.append(UInt8(value & 127) | 128); value >>= 7 }
        data.append(UInt8(value)); return data
    }
    static func integer(_ field: Int, _ value: UInt64) -> Data { varint(UInt64(field << 3)) + varint(value) }
    static func bytes(_ field: Int, _ value: Data) -> Data { varint(UInt64(field << 3 | 2)) + varint(UInt64(value.count)) + value }
    static func string(_ field: Int, _ value: String) -> Data { bytes(field, Data(value.utf8)) }
    static func little(_ value: UInt64, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }) }
    static func double(_ field: Int, _ value: Double) -> Data { varint(UInt64(field << 3 | 1)) + little(value.bitPattern, 8) }
    static func float(_ field: Int, _ value: Float) -> Data { varint(UInt64(field << 3 | 5)) + little(UInt64(value.bitPattern), 4) }
}
