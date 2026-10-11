import Foundation

enum RecordingOutputMode: String, CaseIterable, Codable, Identifiable {
    case gcsv, sonyMOV, gyroflowProtobuf
    var id: String { rawValue }
    var label: String {
        switch self {
        case .gcsv: "原视频+GCSV"
        case .sonyMOV: "Gyroflow Sony Mov"
        case .gyroflowProtobuf: "Gyroflow protobuf Mov（1.6.3 Nightly）"
        }
    }
    var detail: String {
        switch self {
        case .gcsv: "同名 MOV、GCSV、Gyroflow 工程及 lens_profile.json。兼容 Gyroflow 1.6.3。"
        case .sonyMOV: "镜头和 IMU 内嵌 MOV，供 Gyroflow 1.6.3 读取。镜头使用 API 内参近似，主点按画面中心处理，畸变未校准。"
        case .gyroflowProtobuf: "按官方 Protobuf 规范将逐帧内参与 IMU 内嵌 MOV。需要支持 Gyroflow Protobuf 的新版 Gyroflow。硬件读出时刻未知，时间使用 PTS 估计。"
        }
    }
}
