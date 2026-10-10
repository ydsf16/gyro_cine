> Current M1 scope (2026-10-10): selectable physical lens (fixed during each clip), Gyroflow 1.6.3, MOV + GCSV + lens_profile.json + clip.gyroflow. Native JSONL is deferred. See [lens selection](LENS_SELECTION_REPORT.md). See [fixed-lens export report](LEGACY_EXPORT_REPORT.md); earlier sections below are historical.

# M1 真机验收报告 — 2026-10-10

## 状态

**M1 未通过；ProRes RAW 开发未开始。** HEVC/原始 IMU 采集与官方 Protobuf 格式验证已取得真机证据；Gyroflow 同步与实际增稳仍待验收。

## 环境与范围

- Xcode 26.3 (17C529)，签名 Team F2LVFHW3ZH。
- iPhone 16 / iPhone17,3，iOS 18.2.1 (22C161)，有线连接、Developer Mode。
- 用户批准 M1 最低版本降至 iOS 18.2；用户将后续运动测试时长改为 20 秒。3/5 分钟不作为本次已完成测试。
- 主广角固定镜头，3840×2160 / 30fps，HEVC hvc1，AAC 48kHz；EIS off。OIS 状态、镜头参数、物理轴映射及传感器读出时间未经校准。

## 已验证结果

| 请求录制 | MOV 实际时长 | 真实视频帧 | gyro / accel 事件 | 格式校验 |
|---|---:|---:|---:|---|
| 短录制 | 6.4363 s | 193 | 658 / 658 | PASS |
| 60 秒基线 | 62.6633 s | 1880 | 6268 / 6268 | PASS |
| 20 秒运动 | 22.4983 s | 675 | 2260 / 2261 | PASS |

UI 自动化等待录制状态后计时，停止按钮操作会产生额外时长，表格报告真实文件时长。

- 各文件 ffprobe 确认 HEVC 4K，JSONL 行数与实际帧数一致、frameNumber 为 1..N，官方 descriptor 严格解析通过。
- 各传感器中位采样频率 99.7307 Hz；20 秒片段最大间隔 10.0277 ms、重复时间戳 0，音轨存在。
- 运动画面明亮、有纹理；gyro 最大绝对分量约 5.27 rad/s。
- 官方 telemetry-parser 转换器（8bd825db33700c4d4472fae61eada27a65aea7a8）完成 675 条 JSONL → Protobuf → JSONL，帧数与 4521 条 IMU 事件数保持一致。构建转换器时上游 lockfile 不匹配，使用未锁定依赖构建，未将该构建称为可重现锁定构建。
- 真机 XCTest 4/4 于 19:40:41 CST 通过；含真实 AVAssetWriter 零样本控制 buffer 回归。UI 短录制、60 秒、20 秒录制分别通过。
- Python validator 自动化 3/3 通过（合成 HEVC 正例、数字字符串拒绝、帧序错误拒绝）。

## 发现及修复

1. 初次启动时 startRunning 在配置事务内导致失败：调整为 commitConfiguration 后启动。
2. 首次真机录制 MOV 可保存，但 AVAssetReader 零样本控制 buffer 的无效 PTS 导致 sidecar 失败：跳过控制 buffer，按实际 encoded sample 读取 timing，并添加回归测试。
3. 停止时仍追加采样及错误状态保留问题已修复；真机后续录制正常完成。

## Gyroflow 阻塞项

- 已安装 Gyroflow 1.6.3 能打开 HEVC，未自动识别 JSONL；手动导入显示 `Unsupported file format`。
- 官方开发版 1.6.3 (gh2733) 已自动读取同目录 JSONL，UI 显示 Apple iPhone / Contains gyro: Yes、675 帧与运动曲线；CLI 项目和 parsed metadata 导出通过。
- 开发版实测 parsed metadata 中 `has_accurate_timestamps=true`，675 个 `per_frame_time_offsets` 从 0 递减至约 −22.465 秒，证实缺失读出时间造成错误时间映射。当前数据不可作为同步正确的增稳输入。
- 当前官方 parser 对省略的非 optional `startTimestampUs` 使用默认 0，并生成 FirstFrameTimestamp 偏移。这会使播放帧的时间映射无效。官方 protobuf 可解析不代表时间语义正确。
- 本 App 未将 MOV PTS 填充成精确硬件读出时刻。需要在支持 JSONL 的版本中验证明确标注的估算/离线同步方案，或修复上游缺失时间处理后复测。
- 官方开发版通过 https://gyroflow.xyz/devbuild/ 指向的 nightly.link 下载；独立存放，未覆盖 /Applications 的稳定版。开发版日志记录额外 IMU 尾部约 170ms；这是录制停止/回调边界数据，不能当作曝光偏移。
- 实际运动同步偏移、轴映射、镜头校准、增稳导出与前后对比：**未通过**。

## 证据路径（本机，未提交私人视频）

仓库 `artifacts/device_runs/`：

- `second_smoke/recording_20261010_192634/`
- `60s/recording_20261010_192757/`
- `motion20s/recording_20261010_193359/`
- 对应上级目录的 `validation.json`；每个录制目录含 clip.mov、clip.jsonl、imu_raw.jsonl、diagnostics.json、events.log。
- `motion20s/parsed_metadata.json`、录制目录 `clip.gyroflow`；`artifacts/test_logs/gyroflow_nightly_project.log` 与 `gyroflow_nightly_metadata.log`。
- `motion20s/protobuf_binary/`、`motion20s/roundtrip.jsonl`、`motion20s/frame8s.jpg`。
- `first_smoke/` 保留失败实例；`interrupted_long/` 是用户更改时长后切至 Settings 主动中断的片段，不计为长时测试通过。

已复制的长期证据：`artifacts/test_logs/`。原始测试日志：`/tmp/rawmotion_device_ui2.log`、`/tmp/rawmotion_device_60s.log`、`/tmp/rawmotion_device_20s.log`、`/tmp/rawmotion_device_unit.log`。

## 真机复测操作与预期日志

1. 解锁连接手机，运行 App，允许相机/麦克风；确认主摄 4K30、预览和 Settings。
2. 朝向明亮书架/墙面，点击 Record。左右、上下缓慢旋转 20 秒，点击 Stop；等待 Completed。
3. Files → On My iPhone → RawMotionRecorder，导出完整 recording 文件夹；或使用 App Share。
4. 运行 `.venv/bin/python tools/validate_recording.py <folder> --report <validation.json>`。日志应包含 recording → stopping → completed 及实际帧/IMU 数；异常时保留原始文件，不能将失败目录当作合格输出。
5. 按 GYROFLOW_VALIDATION.md 核对实际读取、时间图、离线同步和增稳导出。

## 待验证

- Settings 各参数、拒绝权限、低磁盘、锁屏、热保护和 Share 实际接收结果。
- 本次主动切后台可保留完成文件；其他中断原因未逐项验证。
- CoreMotion 与视频源 PTS epoch 的关系仅有 callback/host clock 诊断，不能据此声称物理曝光同步。

## 20:00 后追加结果

RoamShot 风格 UI、API K 逐帧采集与源 PTS 审计已实现。新的20秒真机片段674帧/4516 IMU事件，全部674帧取得API K、源样本与MOV最大映射残差0.8328ms；真机单元5/5和UI2/2通过。

独立离线 GCSV 工作流消除了缺失 protobuf 时间导致的错误 offsets，真实测得三个同步点35.83/36.99/39.88ms，并由Gyroflow导出4K H.264候选视频674帧。相同471组有效帧对指标显示角度步长变化降低约31%、中心位移步长变化降低约22%。原生JSONL时间语义未修复、畸变/readout/OIS/完整轴标定仍未验收，M1继续保持未通过。

详细结果、边界与复现步骤见 `ISSUE_RESOLUTION.md` 和 `UI_REPORT.md`。最新预览方向修正仅完成模拟器回归；真机再次离线，不能标记该最后改动的真机验证通过。

## 用户范围调整：rolling shutter

用户明确同意 M1 暂不考虑 rolling shutter。当前离线候选未启用 RS 校正、readout 保留未知；不再以未测 readout 阻塞本阶段。保留的原生 JSONL reader 问题是时间映射问题，与是否开启 RS 校正分开处理。轴映射、视觉质量与失败路径尚未完整验收，M1 仍未通过。
