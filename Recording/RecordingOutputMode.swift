import Foundation

enum RecordingOutputMode: String, CaseIterable, Codable, Identifiable {
    case gcsv, sonyMOV, gyroflowProtobuf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gcsv: "GCSV + 原始视频"
        case .sonyMOV: "Sony MOV（兼容实验）"
        case .gyroflowProtobuf: "Gyroflow Protobuf MOV"
        }
    }
    var detail: String {
        switch self {
        case .gcsv: "clip.mov + clip.gcsv + lens_profile.json + clip.gyroflow。兼容 Gyroflow 1.6.3。"
        case .sonyMOV: "镜头和 IMU 内嵌 clip.mov，供 Gyroflow 1.6.3 读取。镜头使用 API 内参近似，主点按画面中心处理，畸变未校准。"
        case .gyroflowProtobuf: "按官方 Protobuf 规范将逐帧内参与 IMU 内嵌 clip.mov。需要支持 Gyroflow Protobuf 的新版 Gyroflow。硬件读出时刻未知，时间使用 PTS 估计。"
        }
    }
}
