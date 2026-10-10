# M2：ProRes RAW 设置与能力检测 — 2026-10-11

## 当前范围与状态

用户在反馈平均曝光补偿有效后，明确要求开始 iPhone 17 Pro RAW 试录，并将编码界面确定为 HEVC / ProRes RAW 两项，RAW 下提供 HQ 开关。随后用户确认暂无 SSD，本阶段收敛到设置与缺少外接存储的提示。

M2 未通过。RAW 实际录制、RAW MOV 完整性、外置盘写入和 Gyroflow 直读/稳定导出均未验证；不因能够选择 RAW 而报告 RAW 录制成功。M1 的历史光学同步验收记录不改为通过。

## 设备与发现

- iPhone 17 Pro / iPhone18,1，iOS 26.0.1（23A365），Xcode 26.3。
- 主摄实际发现 Bayer RAW 4224×3024 @30fps。使用当前 activeFormat 后的动态编码器列表验证 RAW/HQ，不以照片 RAW 格式代替视频能力。
- 首次尝试通过 `AVCaptureVideoDataOutput.recommendedVideoSettings(...outputFileURL:)` 写入 Documents，系统抛出 Objective-C 异常：`Capturing ProRes Raw codec is supported only on external storage device.` 因此内录失败；没有产生有效 RAW MOV。
- 失败原始日志：`artifacts/test_logs/raw17_first_test.log`；详细异常：`artifacts/raw_first_diagnostics/` 的 App 标准输出。该失败目录保存在 `artifacts/device_runs/raw17_first_fail/`，只包含原始 IMU 和事件日志，不能作为可用素材。

## 改动

- 设置提供 HEVC / ProRes RAW，HQ 开关仅在 RAW 下显示。当前编码器及真实尺寸显示在设置中，HQ 对应 aprh，普通 RAW 对应 aprn；不能用时不静默降级 HEVC。
- RAW 会话使用 Bayer 原生缓冲区、锁定白平衡、关闭支持的输出延迟启动，保留采样时钟和原始 IMU 接口。HEVC 排除 Bayer 模式，继续4K30。
- 录制前检查外接存储；没有 SSD 时显示明确提示，在进入 IMU/写文件流程之前返回，避免已发现的内录异常。
- 已准备官方外接存储 URL/权限和写入接口，录制完成后复制到手机素材目录以组装 sidecar，SSD 原片保留。此路径尚未有 SSD 实测，不能报告可用。
- 输出最终编码必须与请求一致；镜头配置会标注实际编码和分辨率。

## 验证

- iOS 编译通过：`artifacts/test_logs/raw17_storage_build.log`。
- 模拟器与 iPhone 17 Pro 单元测试各13/13通过：`artifacts/test_logs/raw17_unit_sim.log`、`raw17_storage_guard_tests.log`。后者的早期UI选择测试失败不能计为通过。
- 使用分段选择器后 RAW/HQ 无 SSD 提示测试2/2通过：`raw17_storage_guard_retest.log`。进一步修正测试点击内层HQ开关，明确断言开关值为1、主界面编码为ProRes RAW HQ；该复测通过：`raw17_hq_verified_test.log`。
- RAW缺盘提示后切回HEVC并完成约5秒短录制通过：`raw17_hevc_return_test.log`；手机目录 `recording_20261011_005631` 已确认存在。设备随后断开，未复制出该片进行桌面二次校验。
- 最新App已由上述真机测试构建、安装并启动（最后测试00:58 CST通过）。测试后设备再次离线，未额外执行独立启动命令。
- 动态编码器报告 `artifacts/device_runs/raw17_capabilities_aprn.json`：主摄格式index69，4224×3024 @30，native pixel format 1651798066，writer codecs包含aprn和aprh；这只是能力查询，不是编码成功证据。
- RAW/HQ 编码稳定性、首录丢帧、存储断开、外录数据复制、RAW 内参和 Gyroflow：未验证。

## 后续操作

1. 设置 → 视频编码 → ProRes RAW；根据需要选择 HQ。无 SSD 时点击录制应明确提示需要外接 SSD，并保持 App 可操作。
2. 接 SSD 后先短录5–20秒，核验 aprn/aprh、视频实际帧数和PTS、IMU、API内参及文件完整性，再用 Gyroflow 1.6.3 读取并导出。
3. 仅在短录通过后扩大时长与外置存储测试。当前不进行5分钟测试。

## 官方依据

- Apple SDK `AVCaptureVideoDataOutput.h`：RAW movie metadata 需要锁定白平衡；查询推荐参数前应配置并启动会话。
- Apple DTS 首次 RAW 延迟启动说明：https://developer.apple.com/forums/thread/839021
- 外接存储 API：https://developer.apple.com/documentation/avfoundation/avexternalstoragedevice
- Gyroflow v1.6.2 声明增加 RAW 支持，v1.6.3 含相关修复；这些发布说明不能代替本项目 RAW 实测：https://github.com/gyroflow/gyroflow/releases/tag/v1.6.2 、https://github.com/gyroflow/gyroflow/releases/tag/v1.6.3
