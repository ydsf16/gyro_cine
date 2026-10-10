> Current M1 scope (2026-10-10): selectable physical lens (fixed during each clip), Gyroflow 1.6.3, MOV + GCSV + lens_profile.json + clip.gyroflow. Native JSONL is deferred. See [lens selection](LENS_SELECTION_REPORT.md). See [fixed-lens export report](LEGACY_EXPORT_REPORT.md); earlier sections below are historical.

# 当前问题与解决路线 — 2026-10-10

用户最新范围：M1 暂不考虑 rolling shutter，关闭 RS 校正。readout 未知不是当前验收阻塞项；不会填入猜测的读出数值。优先完成采集、离线同步、轴方向检查和基础增稳。

## 1. JSONL 支持和时间语义

- 稳定版 Gyroflow 1.6.3 不支持本次官方 JSONL；官方开发版 1.6.3 (gh2733) 已验证自动读取。
- 原生 reader 将缺失的非 optional 硬件 startTimestampUs 按 0 处理，产生错误逐帧 offsets，并设 has_accurate_timestamps=true。
- 目前采用 **独立桌面离线同步输入**：`prepare_gyroflow.py` 从原始 gyro 事件生成官方 GCSV，仅包含真实 gyro 时间和 rad/s，显式选择候选轴方向；原 clip.mov、clip.jsonl 和 imu_raw.jsonl 不修改。GCSV 不替代用户要求的官方 Protobuf JSONL，不能据此宣称原生 JSONL 时间语义已修复。
- 官方 Gyroflow 实测 GCSV 的 per_frame_time_offsets=[]、has_accurate_timestamps=false，并成功执行离线同步。
- 原生 JSONL 的彻底解决应修改并验证 reader 对缺失时间的策略，或取得可靠硬件时间/经验证的估算模型。不能只给 PTS 改字段名，或以 protobuf 解析通过当作时间正确。

规范来源：[官方 Protobuf 文档](https://github.com/gyroflow/docs.gyroflow.xyz/blob/main/technical-details/gyroflow-protobuf.md)、[官方 GCSV 文档](https://docs.gyroflow.xyz/app/technical-details/gcsv-format)。

## 2. 已完成的离线同步与增稳实验

输入：`artifacts/device_runs/roamshot_ui20/recording_20261010_195957/`。

- 22.4653 秒 / 674 帧 / gyro 2258，accel 2258。
- 674 帧全部获得 Apple sample attachment K；中位 K 为桌面验证模型基础，fx 范围 2756.46..2782.74px。取 K 中位数不是精确逐帧镜头模型。
- 验证用 profile 名称 `RawMotion API intrinsics (distortion uncalibrated)`；采用显式零畸变近似，仅写入桌面 profile，不写入官方 protobuf lens 字段。畸变未标定、readout/OIS 未知。
- 候选 IMU orientation=XYZ，纯 gyro integration method=3，未用未经验证正负号的 accel 做 horizon lock。
- 3 个均匀同步区间、每区间 3 秒、offset 搜索 ±0.5 秒。测得 35.83、36.99、39.88ms，跨度 4.05ms。这是本段离线优化结果，不能硬编码到后续录制或当作硬件同步误差上界。
- Gyroflow 真正导出 `offline_v1/candidate.mp4`：H.264 3840×2160、674 帧。候选导出没有音轨；原 MOV 音频保留。CLI 导入 project 后以 project 内输出配置为准，不能把命令行请求的 1080p/audio 当作实际结果。
- 原片与结果在相同的 471 组有效相邻帧对上比较：仿射角度步长变化 RMS 比值 0.6902（降低约31%）；画面中心位移步长变化 RMS 比值 0.7839（降低约22%）。RANSAC >=20 特征、内点比例 >=60%，缩放至 640×360。该指标受主动转动、景深视差、裁切、OIS 影响，**不是完整视觉增稳验收或轴标定证明**。
- 原始 HEVC 的 Gyroflow 随机 seek 同步日志存在 decoder reference/NALU 警告；完整 ffprobe/ffmpeg 解码和帧数通过，候选成功导出。警告保留在日志，后续应复测不同 GOP/软件解码路径，不假定文件损坏或无影响。

日志与结果：`artifacts/test_logs/gyroflow_roamshot_ui20_sync.log`、`gyroflow_roamshot_ui20_render.log`、`roamshot_ui20_comparison.log`；`artifacts/device_runs/roamshot_ui20/offline_v1/` 中的 preparation、profile、preset、sync_parameters、candidate.gyroflow、candidate.mp4、comparison、output_probe。

## 3. 可复现的准备与验证

```sh
.venv/bin/python tools/prepare_gyroflow.py /absolute/recording_folder --output /absolute/new_offline_folder --orientation XYZ
```

输出目录必须全新，防止覆盖。orientation 只作为待验证候选。每条原始 gyro 只输出一次，不复制 JSONL 联合采样中的保持值；时间映射与原始 rad/s 保留。若每帧 API K 都存在，会额外生成明确标为未做畸变标定的桌面 profile。

用官方开发版打开原 MOV，Motion data 手动选择上述 clip.gcsv，加载 api_intrinsics_candidate.json。进行 Auto sync，保存 project，再 Export。保留同步点、参数和原片对比。不要直接使用原 JSONL 导入产生的准确时间标志和错误 offsets。

可重复图像指标：

```sh
.venv/bin/python tools/compare_stabilization.py /absolute/clip.mov /absolute/candidate.mp4 --report /absolute/comparison.json
```

依赖：ffmpeg/ffprobe、protobuf 6.33.0；比较工具额外使用 opencv-python-headless 5.0.0.93、numpy 2.5.3。准备/validator 自动化 5/5 通过。图像比较工具已在真实输入/输出上运行；不将算法自身的运行成功当作质量通过。

## 4. 剩余项如何验收

| 项目 | 具体解决/验收方式 | 当前状态 |
|---|---|---|
| 预览方向 | 安装最后的 preview-only rotation 修正，竖持手机核对取景方向 | 最后真机复测待连接 |
| 轴与加速度正负号 | 静置、单轴 yaw/pitch/roll 各20秒；视觉旋转与 gyro 轴相关比较，锁定镜头/输出方向。静置重力和翻面确定 accel 符号 | XYZ 为候选，未完整标定 |
| 镜头畸变 | 与录制配置一致的棋盘格，覆盖中心/四角/不同倾角；独立验证重投影误差与增稳黑边 | 已取得 API K；畸变未标定 |
| rolling shutter | 按用户要求关闭校正、保留未知值，后续再以受控摇摆/时序参考测量 | 本次明确不纳入 M1 门槛 |
| OIS | `.off` 仅确认 EIS；若增稳出现异常再单独检查 OIS 残差 | 未测量；不声称已关闭 |
| 视觉质量 | 查看候选视频与原片，检查扭曲、黑边、意图运动、同步残差；再做20秒手持走动 | 已导出候选并量化；完整验收待做 |
| 权限 / 磁盘 / 热保护 / 锁屏 | 新安装拒绝权限并恢复；可注入边界条件单测；真机切后台/锁屏等保留文件与错误日志，避免填满用户磁盘 | 后台主动停止曾验证，其他项未逐项通过 |
| Share | 从素材页导出完整目录到 Files，确认 MOV/JSONL/原始数据一起到达 | UI入口已验证，接收端待测 |

**M1 仍未通过，继续禁止 ProRes RAW 开发。** 目前已经可以重复取得离线同步与增稳候选；剩余项按真实证据验收。

## 版本对齐核查（2026-10-10 20:23 CST）

- 官方 release v1.6.2 明确加入 ProRes RAW 支持；GitHub API published_at=2025-08-19T18:35:39Z（北京时间2025-08-20）。来源：https://github.com/gyroflow/gyroflow/releases/tag/v1.6.2 。
- 官方 v1.6.3 是随后修复版，包括 macOS 间歇解码失败修复。目标兼容基线建议采用稳定版 v1.6.3，而不要求用户为了 RAW 必须使用 JSONL 开发版。来源：https://github.com/gyroflow/gyroflow/releases/tag/v1.6.3 。
- 视频解码支持与运动数据格式支持独立。ProRes RAW 支持不意味着官方 Protobuf JSONL 已在相同稳定版提供。稳定版1.6.3和开发版1.6.3(gh2733)不能只凭版本号视作相同构建。
- 针对稳定版建议另导出 clip.gcsv（官方版本1.3），与 clip.mov 同名同目录；保留原始 imu_raw.jsonl、诊断/逐帧证据及原要求的官方 clip.jsonl。GCSV不携带伪造硬件readout时间，可用离线运动同步；官方JSONL仍需独立修复和验收。该建议尚未改为App自动GCSV导出。
- 本机 /Applications/Gyroflow.app 稳定版1.6.3 已实际读取新20秒片段的GCSV：2258条gyro、per_frame_time_offsets=[]、has_accurate_timestamps=false。日志 artifacts/test_logs/stable163_gcsv_metadata.log；解析结果 artifacts/device_runs/roamshot_ui20/stable163/parsed_metadata.json。只验证了稳定版读取，不能将此前开发版同步/导出结果计为稳定版的端到端通过。
- 尚无本项目真实ProRes RAW文件测试；发行说明的支持声明不代表 iPhone RAW 输入、RAW增稳导出或RAW编码已验收。M1门槛与禁止RAW开发的约束仍保持。
