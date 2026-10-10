# 三种输出模式验收报告

日期：2026-10-11

## 交付

设置中的“保存格式”提供三项，选择持久保存，录制开始时锁定所选模式：

| 模式 | 最终交付 | 兼容性 |
| --- | --- | --- |
| GCSV + 原始视频 | clip.mov、clip.gcsv、lens_profile.json、clip.gyroflow | Gyroflow 1.6.3 |
| Sony MOV | clip.mov 内嵌 rtmd IMU 与 Sony lens fallback 数据 | Gyroflow 1.6.3，兼容实验 |
| Gyroflow Protobuf MOV | clip.mov 内嵌 gyrf 官方 Protobuf 数据 | 支持该协议的新版本，1.6.3 不支持 |

所有模式保持每次一个 recording_时间 文件夹；保留 imu_raw.jsonl、video_samples.jsonl、diagnostics.json、日志。内嵌模式额外保留 embedded_metadata.json（真实镜头配置、近似状态和同步说明）。不生成 ZIP。编码选择 HEVC/RAW/HQ 与保存格式独立。

内嵌使用临时副本、追加元数据轨、保留原始视频/音频轨的样本描述和 chunk offset，检查编码/尺寸/每帧 PTS 后原子替换 clip.mov。失败保留原始文件及 GCSV 交付文件。会临时需要约一个视频大小的额外空间。导出工作在后台运行。

## 已验证

- iOS 真机目标编译：通过（Xcode 26.2 SDK，部署最低 iOS 18.2）。
- 模拟器单元测试：18 项通过；覆盖 MOV 原始 mdat 不变、视频编码和 PTS 不变、失败回退、Protobuf wire type/单位及非有限值拒绝、Sony 数值溢出拒绝。
- 设置 UI 自动化：1 项通过；切换三种模式，并重启确认选择持久化。
- 使用下载目录 recording_20261011_015006 原始 ProRes RAW aprn 数据，经 App 的同一 Swift finalizer 生成全部三种模式：通过。
- 三种模式：345 个视频包及 268 个音频包的 SHA256、PTS、DTS、duration、size 均与原始文件一致。
- Protobuf 官方生成的 Python 解码器：345 帧、345 组逐帧 K、577 个 IMU 样本，曝光 9370 µs，全部数值有限；gyro 度/秒和原始时间映射逐样本比对通过。
- 旧 Gyroflow 1.6.3 实际解析 Sony MOV：自动识别内嵌 IMU 和镜头；支持 Protobuf 的 Nightly 实际解析 Protobuf MOV：识别 Apple iPhone18,1 和内嵌镜头。
- git diff --check：通过。

证据：artifacts/output_modes/acceptance.json；artifacts/output_modes/real_raw；artifacts/OutputModesSim/Logs/Test。构建日志 /tmp/output-modes-build.log，单元测试 /tmp/output-modes-tests.log，UI 测试 /tmp/output-modes-ui.log，实际 Swift 导出 /tmp/output-modes-real.log，Gyroflow 解析 /tmp/app-sony-parser.log 和 /tmp/app-proto-parser.log。

## 限制与待验收

- 2026-10-11 已通过 devicectl 安装到 iPhone 17 Pro（com.tinygrape.RawMotionRecorder），并成功启动。三种模式的新真机录制仍待用户验证，不能标为真机录制通过。
- Sony 模式使用虚拟传感器几何将 API K 投影到 Sony 字段。显示的物理焦距、传感器尺寸不是 iPhone 实测值。旧解析器主点取画面中心，原始 API K 保留在私有信息中。畸变未标定。
- Protobuf 按仓库官方 schema 的字段和 wire type 写入；未知像素间距、物理传感器尺寸和 rolling shutter 不伪造。读出时刻为 PTS + 当前曝光/2 的模型估计，header.additional_data 明确声明硬件读出未知。IMU 沿用已接受的正平均半曝光补偿。光学时间对齐仍需真机验收。
- 新版 RAW 原片直接导入后导出颜色的问题未解决，本次仅增加保存格式，不声称 RAW 彩色增稳导出通过。

## 真机操作与日志

1. 连接并解锁 iPhone 17 Pro，安装新版；RAW 录制时接 SSD。
2. 设置 → 保存格式 → 分别选择三种模式。固定镜头，明亮纹理场景，缓慢转动，每种录制约 20 秒。
3. 文件 → 我的 iPhone → RawMotionRecorder：每次录制仍是独立文件夹。核对上述模式对应文件，原始 IMU 和逐帧信息始终存在。
4. GCSV 模式打开 clip.gyroflow；Sony 模式在 1.6.3 直接打开 clip.mov；Protobuf 模式在支持该协议的新版直接打开 clip.mov。
5. 核对自动识别 IMU/镜头；查看曝光和实际时间映射，再验收 AutoSync 残差及增稳画面，不能仅凭能打开标为通过。
6. diagnostics.json 应显示 outputMode 为 gcsv / sonyMOV / gyroflowProtobuf；内嵌模式显示 embeddedTelemetryStatus。日志中 completed 表示文件处理完成，optical sync / RAW color export unverified 表示后续视觉验收仍待完成。

## 加速度符号更新

- 按用户要求，Sony RTMD、Gyroflow Protobuf 及旧 JSONL writer 的导出加速度 XYZ 全部取反；单位保持 Sony g / Protobuf m/s²。陀螺仪符号与时间映射不变。imu_raw.jsonl 保留 CoreMotion 原始值。GCSV 当前只包含陀螺仪，不增加额外字段。
- 编译通过；最新单元测试 19 项全部通过，新增序列化测试检查 Sony 三轴整数值、Protobuf 三轴负号及陀螺仪不变。日志：/tmp/acceleration-sign-build.log、/tmp/acceleration-sign-tests.log。
- 上述真实 RAW 的字节保持和解码验收属于三种输出模式版本；加速度更新后的新真机录制尚待验收。当前安装在手机上的版本尚未包含此次加速度修改。
