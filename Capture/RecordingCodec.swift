import AVFoundation

enum RecordingCodec: String, CaseIterable, Identifiable {
    case hevc, proResRAW, proResRAWHQ
    var id: String { rawValue }
    var label: String {
        switch self {
        case .hevc: "HEVC"
        case .proResRAW: "ProRes RAW"
        case .proResRAWHQ: "ProRes RAW HQ"
        }
    }
    var isRAW: Bool { self != .hevc }
    var avCodec: AVVideoCodecType? {
        if self == .hevc { return .hevc }
        if #available(iOS 26.0, *) { return self == .proResRAW ? .proResRAW : .proResRAWHQ }
        return nil
    }
    var fourCC: String { self == .hevc ? "hvc1" : self == .proResRAW ? "aprn" : "aprh" }
}
