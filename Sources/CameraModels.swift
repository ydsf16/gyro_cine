import AVFoundation

enum VideoEncoding: String, CaseIterable, Identifiable {
    case hevc, hevcHQ, proResRAW, proResRAWHQ
    case proRes422HQ, proRes422, proRes422LT, proRes422Proxy
    var id: Self { self }
    var title: String {
        switch self {
        case .hevc: "H.265"
        case .hevcHQ: "H.265 HQ"
        case .proResRAW: "ProRes RAW"
        case .proResRAWHQ: "ProRes RAW HQ"
        case .proRes422HQ: "ProRes 422 HQ"
        case .proRes422: "ProRes 422"
        case .proRes422LT: "ProRes 422 LT"
        case .proRes422Proxy: "ProRes 422 Proxy"
        }
    }
    var codec: AVVideoCodecType {
        switch self {
        case .hevc, .hevcHQ: .hevc
        case .proResRAW: AVVideoCodecType(rawValue: "aprn")
        case .proResRAWHQ: AVVideoCodecType(rawValue: "aprh")
        case .proRes422HQ: .proRes422HQ
        case .proRes422: .proRes422
        case .proRes422LT: .proRes422LT
        case .proRes422Proxy: .proRes422Proxy
        }
    }

    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }
    var isProRes422: Bool {
        switch self {
        case .proRes422HQ, .proRes422, .proRes422LT, .proRes422Proxy: true
        default: false
        }
    }

    // Conservative estimates until the existing per-device bitrate learner has samples.
    var estimatedBitsPerPixelPerFrame: Double {
        switch self {
        case .proResRAWHQ: 8
        case .proResRAW: 6
        case .proRes422HQ: 4
        case .proRes422: 3
        case .proRes422LT: 2
        case .proRes422Proxy: 1.2
        case .hevc, .hevcHQ: 0.5
        }
    }
}

enum RecordingColorSpace: String, CaseIterable, Identifiable {
    case systemDefault, rec709, rec2020HDR, p3D65, appleLog, appleLog2
    var id: Self { self }
    static var selectableCases: [Self] { allCases.filter { $0 != .systemDefault } }
    static func restored(_ value: String?) -> Self {
        let stored = value.flatMap(Self.init(rawValue:)) ?? .rec709
        return stored == .systemDefault ? .rec709 : stored
    }

    func title(locale: Locale) -> String {
        switch self {
        case .systemDefault: AppText.value("系统默认", "System Default", locale: locale)
        case .rec709: "Rec.709"
        case .rec2020HDR: "Rec.2020 · HDR"
        case .p3D65: "P3 D65"
        case .appleLog: "Apple Log"
        case .appleLog2: "Apple Log 2"
        }
    }

    var captureColorSpace: AVCaptureColorSpace? {
        switch self {
        case .systemDefault: nil
        case .rec709: .sRGB
        case .rec2020HDR: .HLG_BT2020
        case .p3D65: .P3_D65
        case .appleLog: .appleLog
        case .appleLog2:
            if #available(iOS 27.0, *) { .appleLog2 } else { nil }
        }
    }

    func isAvailable(for format: AVCaptureDevice.Format, encoding: VideoEncoding) -> Bool {
        if self == .systemDefault { return true }
        guard !encoding.isRAW, let captureColorSpace else { return false }
        return format.supportedColorSpaces.contains(captureColorSpace)
    }
}

/// Requested H.265 encoder rate. H.265 HQ keeps its existing encoder settings.
enum HEVCBitratePreset: String, CaseIterable, Identifiable {
    case compact, balanced, quality, maximum
    var id: Self { self }

    // Preserve the first three stored values from the previous UI. Its old
    // "automatic" value and fresh installs now use the middle tier.
    static func stored(_ value: String?) -> Self {
        Self(rawValue: value ?? "") ?? .balanced
    }

    func title(locale: Locale) -> String {
        switch self {
        case .compact: AppText.value("低", "Low", locale: locale)
        case .balanced: AppText.value("中", "Medium", locale: locale)
        case .quality: AppText.value("高", "High", locale: locale)
        case .maximum: AppText.value("最高", "Max", locale: locale)
        }
    }

    func targetBitsPerSecond(width: Int32, height: Int32, fps: Double) -> Int? {
        let bitsPerPixelPerFrame: Double
        switch self {
        case .compact: bitsPerPixelPerFrame = 0.06
        case .balanced: bitsPerPixelPerFrame = 0.10
        case .quality: bitsPerPixelPerFrame = 0.18
        case .maximum: bitsPerPixelPerFrame = 0.24
        }
        guard width > 0, height > 0, fps.isFinite, fps > 0 else { return nil }
        return Int(min(200_000_000, max(2_000_000,
            Double(width) * Double(height) * fps * bitsPerPixelPerFrame)).rounded())
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
         "colorSpaces": RecordingColorSpace.allCases.filter {
             $0 != .systemDefault && $0.captureColorSpace.map(format.supportedColorSpaces.contains) == true
         }.map(\.rawValue),
         "autoFocusSystem": autofocus, "fieldOfViewDegrees": format.videoFieldOfView,
         "supportsIntrinsics": supportsIntrinsics, "compatibleCodecs": compatibleCodecs.sorted()]
    }
}

enum CaptureFrameRatePolicy {
    static let maximum = 120.0
    private static let common = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60, 119.88, 120]

    static func normalized(_ fps: Double) -> Double {
        fps.isFinite && fps > 0 ? min(fps, maximum) : 30
    }

    static func available(for format: FormatInfo) -> [Double] {
        let standard = common.filter(format.supports)
        if !standard.isEmpty { return standard }
        let endpoints = format.format.videoSupportedFrameRateRanges.flatMap { range in
            [range.minFrameRate, min(range.maxFrameRate, maximum)]
        }.filter { $0 > 0 && $0 <= maximum && format.supports($0) }
        return Array(Set(endpoints)).sorted()
    }
}
