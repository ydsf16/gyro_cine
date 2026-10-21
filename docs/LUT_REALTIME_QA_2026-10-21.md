# LUT 实时烧录与紧凑面板

## 本次改动

- LUT 选择卡片从 225×38 缩为 150×34；烧录文字、图标与橙色开关同一行。
- 非 RAW 开启烧录时，复用全尺寸 VideoDataOutput 帧，在独立串行队列通过 Metal CIContext 处理，再送 AVAssetWriter；音频 AAC、场记、方向和原始视频 PTS 保留。
- 视频采集入口最多保留 10 帧，音频最多 32 包；编码像素池最多 10 个。积压或持续严重丢帧会停止并报告。采集、预览、IMU 不等待录制队列的 GPU 工作。
- 编码器准备期间不建立录制时间轴；就绪后以新采集帧 PTS 开始。没有对正常录制期间的丢帧压缩时间。
- 新录像的 IMU 恢复任务不再安排录后 LUT 转码。旧版本遗留的录后任务仍可恢复。
- 烧录关闭继续走原 MovieFileOutput；RAW/RAW HQ 不允许烧录，原 RAW 写入路径不变。
- 加入剩余空间监控、生命周期停止、SSD 断开处理；高位深必须取得设备支持的 10-bit 采集输出，否则明确拒绝。

## 真机结果

设备：iPhone 16 YJJY，iOS 18.2.1，USB，内部文件，H.265 4K60。

| 用例 | 结果 |
|---|---|
| 20 秒导入红色 LUT | 1205 帧完整解码；最大间隔 16.717ms，无估计丢帧；像素 RGB≈253/0/0，确认实际烧入；AAC/IMU 轨存在 |
| 60 秒 Rec.709 LUT | 3602 帧完整解码；最大间隔 16.716ms，无估计丢帧；AAC 双声道与 IMU 轨存在 |
| 60 秒录制效率 | GPU 每帧平均 7.03ms、最大 13.07ms；采集缓冲峰值 1 帧；停止至编码完成 0.055 秒，随后 IMU 封装 1.952 秒 |
| XCTest 紧凑控件/管理页 | 通过：开关、隐藏/启用、重启持久化、导入器打开/取消；截图已保存 |
| XCTest 同次启动开→关→开 | 三段录制和保存全部完成，无弹窗；每段 IMU 封装完成。关闭烧录片 329 帧完整解码且无 LUT 标记 |
| 人工阻塞录制队列 300ms | 达到 10 帧触发停止和明确提示；保留文件，失败 IMU 任务退役，避免反复补写弹错 |
| 高位深拒绝路径 | 此 SDR 格式不提供所需 10-bit 输出；明确提示，无静默 8-bit 降级 |
| 最终编译版短录制 | 8.016 秒、481 帧，最大间隔 16.683ms，估计缺帧 0，AAC/IMU 存在；停止编码 0.050 秒，IMU 封装 0.296 秒 |

以上是当前场景的测量值，不是任意场景的性能保证。故障注入片不计作成功交付素材。

## 未覆盖

- 本机不支持 ProRes 相机录制；ProRes、Log/HDR 10-bit、SSD/PVS 的实时烧录需要相应设备验证。此前离线 ProRes 烧录测试不能替代本次实时录制测试。
- 本轮最长 60 秒；未进行长时间高温或磁盘耗尽的实测。
- 已验证保持 PTS 和内嵌 IMU；本轮未做 Gyroflow 光学同步或增稳效果测试。

## 复测

- `IMURecordingUITests/testLUTManagementAndBurnControls`
- `IMURecordingUITests/testRealtimeLUTOnOffOnRecording`
- Debug：`--hevc-4k60-smoke --lut-realtime-smoke --lut-test-seconds=60`
- 导入红色标记：`--lut-import-smoke -lutBurnEnabled YES`
- 阻塞保护：额外加 `--lut-stall-smoke`（仅 Debug）
- 文件帧间隔：`python3 tools/analyze_capture_cadence.py --fps 60 <MOV>`

证据：`docs/qa-evidence/2026-10-21-lut-realtime/`。
XCTest：`/tmp/lut-realtime-ui.xcresult`、`/tmp/lut-realtime-repeat.xcresult`。
本次未 commit、未推送。

## 内置 LUT 管理与双语回归

- 内置 6 个 LUT 与导入 LUT 均支持显示开关，分别分组。
- 关闭当前 LUT 同步关闭预览与烧录；设置持久保存；主界面仅列出启用项。
- 手动开启烧录时，若原 LUT 已禁用，选择一个启用项；没有启用项时不开启烧录。
- iPhone 16 真机 `testBuiltinLUTManagementChineseAndEnglish` 通过：中文/英文标题与名称、开关、主界面隐藏和恢复、设置与主屏烧录状态联动。
- 测试结果：`/tmp/lut-builtin-localization.xcresult`；截图：`/tmp/lut-builtin-localization-images/`。
