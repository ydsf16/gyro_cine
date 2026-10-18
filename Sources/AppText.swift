import Foundation

enum AppText {
    static func value(_ chinese: String, _ english: String, locale: Locale) -> String {
        let language = Bundle.main.preferredLocalizations.first ??
            Locale.preferredLanguages.first ?? locale.identifier
        return language.lowercased().hasPrefix("zh") ? chinese : english
    }
}

extension AppText {
    /// Presentation only. Keep original errors unchanged for recovery classification and diagnostics.
    static func message(_ raw: String, language: String? = nil) -> String {
        let chinese = (language ?? Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "en").lowercased().hasPrefix("zh")
        let rules: [([String], String, String)] = [
            (["视频与 IMU 已保存，但"], "视频和 IMU 已保存，但录制存在丢帧，请检查画面。", "Video and IMU were saved, but frames were dropped. Please check the clip."),
            (["RAW 拍摄需要保持白平衡锁定"], "RAW 拍摄需要锁定白平衡，请选择手动模式或色温预设。", "RAW recording requires locked white balance. Choose Manual or a white balance preset."),
            (["ProRes RAW 需要专用视频存储", "ProRes RAW 请在设置中选择"], "ProRes RAW 需要专用视频存储或外部 SSD，请在设置中选择。", "ProRes RAW requires Pro Video Storage or an external SSD. Choose a storage location in Settings."),
            (["不支持专用视频存储", "does not support Pro Video Storage"], "此设备或系统不支持专用视频存储，请使用外部 SSD。", "Pro Video Storage is not supported on this device or OS. Use an external SSD."),
            (["专用视频存储未分配", "请先配置可用的专用视频存储"], "请先在系统设置中分配专用视频存储空间，或选择外部 SSD。", "Allocate Pro Video Storage in system Settings, or choose an external SSD."),
            (["专用视频存储正在处理"], "专用视频存储正在处理文件，请稍后重试。", "Pro Video Storage is busy. Please try again shortly."),
            (["未检测到已选择的外部 SSD", "未检测到外部 SSD", "请连接并选择 SSD", "SSD 素材授权已失效", "无法访问 SSD 素材"], "请重新连接 SSD，并在设置中检查存储选择和访问权限。", "Reconnect the SSD and check the storage selection and access permission in Settings."),
            (["剩余空间不足", "空间不足", "No space left"], "存储空间不足。请清理空间或选择其他存储位置后再录制。", "Not enough storage space. Free up space or choose another storage location before recording."),
            (["视频帧时间异常", "视频帧率严重不足", "视频帧不足", "无效或重复帧时间"], "视频帧数据异常，无法完成 IMU 封装。请检查原片，并降低录制规格或检查存储性能。", "The video has invalid or missing frames and IMU embedding could not complete. Check the original clip, lower recording settings, or check storage performance."),
            (["10 帧", "缓冲", "写入速度", "写入阻塞", "速度不足", "严重丢帧"], "写入速度不足或录制严重掉帧。请检查存储性能，或降低分辨率和帧率后重试。", "Writing could not keep up or recording dropped too many frames. Check storage performance or lower the resolution and frame rate."),
            (["SSD 录制中断"], "SSD 录制中断，原始文件已保留。请重新连接 SSD 后检查素材。", "SSD recording was interrupted. The original file was retained. Reconnect the SSD and check the clip."),
            (["麦克风权限", "Microphone permission", "microphone access"], "录制需要麦克风权限，请在系统设置中允许访问。", "Microphone access is required for recording. Allow access in system Settings."),
            (["Camera permission", "相机权限"], "请在系统设置中允许相机访问。", "Allow camera access in system Settings."),
            (["Rear physical camera unavailable", "Back wide camera was not found"], "无法使用相机，请关闭其他相机 App 后重试。", "The camera is unavailable. Close other camera apps and try again."),
            (["cannot change during recording", "录制尚未结束"], "请等待录制和保存完成后再操作。", "Wait for recording and saving to finish before making this change."),
            (["Lens switch:", "Camera input unavailable"], "镜头切换失败，请稍后重试或选择其他镜头。", "Could not switch lenses. Try again or choose another lens."),
            (["当前视频配置暂不可用", "Codec unavailable", "No compatible format", "No supported video encoding", "Format configuration:", "FPS configuration:", "Invalid format selection", "No active video format", "unavailable on format", "unsupported at the selected resolution", "Current codec/format combination"], "当前组合不可用，请重新选择编码、分辨率和帧率。", "This recording combination is unavailable. Choose another codec, resolution, or frame rate."),
            (["Shutter angle:", "Shutter angle is unavailable", "Exposure:", "A-Max:", "Exposure compensation:"], "无法应用曝光设置，请选择设备支持的范围后重试。", "Could not apply the exposure setting. Choose a value supported by this camera and try again."),
            (["White balance:", "无法锁定白平衡"], "无法应用白平衡设置，请重试。", "Could not apply white balance. Please try again."),
            (["Focus:", "Unsupported focus:"], "当前镜头不支持此对焦操作，请选择其他对焦模式。", "This lens does not support the requested focus operation. Choose another focus mode."),
            (["无法准备 RAW 输出", "无法准备音频输出", "Camera setup:", "Cannot add camera", "Cannot add microphone"], "相机初始化失败，请重新打开 App 后重试。", "Camera setup failed. Reopen the app and try again."),
            (["IMU 启动失败", "陀螺仪或加速度计不可用", "IMU 预录", "内参记录启动失败"], "运动数据或相机内参尚未就绪，请稍后重试。", "Motion data or camera calibration is not ready. Please try again shortly."),
            (["视频录制未完成", "录制已停止", "SSD 录制启动失败"], "录制未能正常完成，请检查素材和存储状态后重试。", "Recording did not finish normally. Check the clip and storage status before trying again."),
            (["RAW 录制已取消：App 不在前台"], "请返回 App 后开始录制。", "Return to the app before starting recording."),
            (["相机不支持当前重力方向"], "无法确定录制方向，请调整手机姿态后重试。", "Recording orientation is unavailable. Adjust the phone's position and try again.")
        ]
        for (keys, zh, en) in rules where keys.contains(where: raw.contains) { return chinese ? zh : en }
        // Existing bilingual SSD messages are displayed in one language only.
        let parts = raw.components(separatedBy: " / ")
        if parts.count == 2 && containsChinese(parts[0]) && !containsChinese(parts[1]) {
            return chinese ? parts[0] : parts[1]
        }
        if !chinese && containsChinese(raw) {
            return "The operation could not be completed. Please try again."
        }
        if chinese && !containsChinese(raw) && (raw.contains("unavailable(") || raw.contains("Error") || raw.contains("failed")) {
            return "操作未能完成，请重试。"
        }
        return raw
    }
    private static func containsChinese(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }
}
