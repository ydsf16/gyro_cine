# 快门与 iPhone 文件夹验收 — 2026-10-11

## 当前结论

- 最新 App 已安装并启动于 iPhone 16（iOS 18.2.1，`com.tinygrape.RawMotionRecorder`）。
- 每次录制直接写入“文件 → 我的 iPhone → RawMotionRecorder → recording_时间戳”；不生成 ZIP。
- 设置中提供自动、1/30、1/60、1/120、1/240 秒，按当前实体镜头的 4K30 格式筛选可用档位。固定快门同时锁定设置时的 ISO，暗光可能曝光不足。
- M1 增稳画质和光学同步尚未验收；不开始 ProRes RAW。

## 真机证据

- 真机自动化 `testDeviceManualShutterRecording` 通过；12/12 单元测试通过。日志：`artifacts/test_logs/shutter_device_tests.log`。
- `recording_20261011_000459`：主摄、请求 1/120 秒、188 帧、实际 MOV 6.2667 秒；逐帧回调时相机曝光读数中位数 0.008332 秒，ISO 中位数 64.97。`tools/validate_legacy_recording.py` 报 `PASS-format-and-clock-mapping`，源帧/MOV PTS 最大残差 0.375 ms。真机原始目录已复制到 `artifacts/device_runs/shutter_000459/`。
- iPhone 上 `recording_20261011_000516` 目录含 `clip.mov`、`clip.gcsv`、`lens_profile.json`、`clip.gyroflow`，以及四个诊断/原始文件。该目录的格式和时钟映射校验通过。
- 快门读数取自视频样本回调时的 `AVCaptureDevice.exposureDuration`，不能当作每帧硬件曝光开始时间。此前用户的 349 帧 MOV 无曝光元数据，实际快门不可追溯。

## 未通过或待测

- 文件夹分享界面曾显示“存储到文件”操作，但 UI 测试使用固定导航标题 `1个文稿` 判断数量时失败。已移除这个与系统语言/布局相关的断言；手机离线使复测未执行。手机“文件”中的原始录制目录已用设备文件 API 独立确认。
- Gyroflow 1.6.3 实际打开新目录、AutoSync 剩余偏差和稳定导出画质需要用户在明亮有纹理场景下复测；格式/时钟校验通过不代表这些通过。

## 用户操作

1. 打开 App → 设置 → 快门，选择需要的档位；返回预览确认曝光读数。
2. 录制后等待 `Completed`，打开 iPhone“文件”→“我的 iPhone”→“RawMotionRecorder”→最新 `recording_...`。
3. 将整个文件夹复制到 Mac，同目录打开 `clip.gyroflow`。记录 Gyroflow AutoSync 每个同步点的毫秒值、所用快门档位及场景亮度。
