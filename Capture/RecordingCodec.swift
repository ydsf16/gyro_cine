import AVFoundation

enum RecordingCodec: String, CaseIterable, Identifiable {
    case h264, hevc, proRes422, proRes422HQ, proResRAW, proResRAWHQ
    static let selectableCases: [RecordingCodec] = [.hevc, .proResRAW, .proResRAWHQ]
    var id: String { rawValue }
    var label: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "H.265 / HEVC"
        case .proRes422: "ProRes 422"
        case .proRes422HQ: "ProRes 422 HQ"
        case .proResRAW: "ProRes RAW"
        case .proResRAWHQ: "ProRes RAW HQ"
        }
    }
    var isRAW: Bool { self == .proResRAW || self == .proResRAWHQ }
    var avCodec: AVVideoCodecType? {
        if self == .h264 { return .h264 }
        if self == .hevc { return .hevc }
        if self == .proRes422 { return .proRes422 }
        if self == .proRes422HQ { return .proRes422HQ }
        if #available(iOS 26.0, *) { return self == .proResRAW ? .proResRAW : .proResRAWHQ }
        return nil
    }
    var fourCC: String {
        switch self {
        case .h264: "avc1"
        case .hevc: "hvc1"
        case .proRes422: "apcn"
        case .proRes422HQ: "apch"
        case .proResRAW: "aprn"
        case .proResRAWHQ: "aprh"
        }
    }
    var isProRes: Bool { self != .h264 && self != .hevc }
}
