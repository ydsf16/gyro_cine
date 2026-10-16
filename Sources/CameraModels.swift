import AVFoundation

enum VideoEncoding: String, CaseIterable, Identifiable {
    case hevc, hevcHQ, proResRAW, proResRAWHQ
    var id: Self { self }
    var title: String {
        switch self {
        case .hevc: "H.265"
        case .hevcHQ: "H.265 HQ"
        case .proResRAW: "ProRes RAW"
        case .proResRAWHQ: "ProRes RAW HQ"
        }
    }
    var codec: AVVideoCodecType {
        switch self {
        case .hevc, .hevcHQ: .hevc
        case .proResRAW: AVVideoCodecType(rawValue: "aprn")
        case .proResRAWHQ: AVVideoCodecType(rawValue: "aprh")
        }
    }
}

enum ShutterMode { case auto, autoMax, manual, angle }

enum FocusChoice: String, CaseIterable, Identifiable {
    case continuous = "Continuous AF", single = "Single AF", locked = "Locked"
    case manual = "Manual", tap = "Tap to Focus"
    var id: String { rawValue }
}

struct LensChoice: Identifiable {
    let id: String
    let label: String
}

struct FormatInfo: Identifiable {
    let index: Int
    let format: AVCaptureDevice.Format
    let width: Int32
    let height: Int32
    let fourCC: String
    let fpsDescription: String
    let autofocus: String
    var compatibleCodecs: Set<String> = []
    var supportsIntrinsics = false
    var id: Int { index }
    var label: String { "[\(index)] \(width)×\(height) | \(fourCC) | \(fpsDescription) fps | \(autofocus) | K \(supportsIntrinsics ? "✓" : "—")" }

    init(index: Int, format: AVCaptureDevice.Format) {
        self.index = index; self.format = format
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        width = dimensions.width; height = dimensions.height
        let code = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        let bytes = (0..<4).map { UInt8((code >> (24 - $0 * 8)) & 0xff) }
        fourCC = String(bytes: bytes, encoding: .ascii) ?? String(format: "0x%08X", code)
        fpsDescription = format.videoSupportedFrameRateRanges.map {
            String(format: "%.3g–%.3g", $0.minFrameRate, $0.maxFrameRate)
        }.joined(separator: ", ")
        switch format.autoFocusSystem {
        case .none: autofocus = "None"
        case .contrastDetection: autofocus = "Contrast"
        case .phaseDetection: autofocus = "Phase Detection"
        @unknown default: autofocus = "Unknown"
        }
    }

    func supports(_ fps: Double) -> Bool {
        format.videoSupportedFrameRateRanges.contains { fps >= $0.minFrameRate - 0.001 && fps <= $0.maxFrameRate + 0.001 }
    }

    var dictionary: [String: Any] {
        ["index": index, "width": width, "height": height, "pixelFormat": fourCC,
         "fpsRanges": format.videoSupportedFrameRateRanges.map { ["min": $0.minFrameRate, "max": $0.maxFrameRate] },
         "autoFocusSystem": autofocus, "fieldOfViewDegrees": format.videoFieldOfView,
         "supportsIntrinsics": supportsIntrinsics, "compatibleCodecs": compatibleCodecs.sorted()]
    }
}
