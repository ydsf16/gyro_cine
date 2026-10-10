# 自动曝光上限与平均曝光时间补偿 — 2026-10-11

## 实现

- 使用 `continuousAutoExposure` + `activeMaxExposureDuration`，由 iOS 自动调整快门和 ISO。设置改为“最长曝光时间”，提供系统默认、1/30、1/60、1/120、1/240 秒；后四项是上限，不是固定快门。
- 结束录制后，以每个编码帧对应的 `deviceExposureDurationAtCallbackSeconds` 求算术平均，补偿值为平均值的一半。
- 根据用户实测的正偏移与 Gyroflow 的 `gyroTime = videoTime - offset` 约定，将 GCSV 时间整体增加该补偿值，然后使用录制前后的原始 IMU 重新插值边界、裁剪到视频区间。GCSV 第一条仍为 0，项目 offsets 仍为 0，防止重复补偿。IMU 采样间隔不被逐帧改变，原始 JSONL 和 MOV 保留。
- `diagnostics.json.gcsvAlignment` 保存 `positive_mean_half_exposure_v1`、实际补偿毫秒数及逐帧半曝光的最小/最大值；缺失帧曝光读数会保留原始文件并报告失败。

## 模型边界

- 正半曝光是针对当前设备观察到的经验模型，不宣称 Apple PTS 是某个硬件曝光边界。曝光属性在样本回调时读取，并非每帧硬件嵌入元数据。
- 自动曝光变化时，整段固定平均补偿仍有逐帧残差；其曝光项约为 `(该帧曝光 - 平均曝光) / 2`。本次不引入逐帧时间扭曲。
- 用户两段超广角数据实测：1/30 实际 32.964 ms（半值16.482 ms），1/240 实际4.160 ms（半值2.080 ms）；光学同步结果与半曝光接近但不完全相等。新版增稳画质仍需复测。

## 验证

- 00:32 CST 已通过有线安装并启动新版于 iPhone 16 / iOS 18.2.1，日志：`artifacts/test_logs/autoexposure_comp_install.log`。

- iOS 编译通过：`artifacts/test_logs/autoexposure_comp_build.log`。
- 模拟器单元测试13/13通过：`artifacts/test_logs/autoexposure_comp_sim_tests.log`。覆盖补偿方向、平均值、原始IMU边界插值、缺失或非法曝光拒绝。
- 真机13/13单元测试及 `testDeviceCappedExposureRecording` 通过：`artifacts/test_logs/autoexposure_comp_device_tests.log`。
- `recording_20261011_003059`：主摄187帧、6.2333秒，设置上限1/120秒，所有帧曝光读数8.317ms，ISO由104.69至175.00，补偿4.1585ms。GCSV有624样本、首时间为0、项目offset为0；原始IMU及源/MOV映射独立校验通过，最大残差0.3701ms。
- 文件证据：`artifacts/device_runs/autoexposure_comp_003059/validation.json`、`diagnostics.json`、`video_samples.jsonl`。本次场景曝光持续处于上限，验证了ISO变化；更亮场景下自动缩短快门需后续观察。
- M1 光学同步及最终增稳效果仍待新片复测，未标记通过。

## 真机操作

1. 设置“最长曝光时间”为1/120秒，朝向有纹理的场景；亮暗变化时观察曝光读数与ISO。
2. 录制20秒后等待Completed。在“文件 → 我的iPhone → RawMotionRecorder”复制整个新目录。
3. 打开该目录的clip.gyroflow进行稳定测试；AutoSync结果应解释为平均曝光补偿后的剩余偏差，不再额外手动加半曝光。

API依据：https://developer.apple.com/documentation/avfoundation/avcapturedevice/activemaxexposureduration
