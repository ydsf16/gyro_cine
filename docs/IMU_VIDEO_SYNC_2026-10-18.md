# IMU 与视频时间对齐调查（2026-10-18）

## 时间基准与现有实现

- CoreMotion 的陀螺仪时间戳是开机后的单调秒数。`AVCaptureMovieFileOutput` 的起始 PTS 与逐帧 K 输出的 PTS 通过 `AVCaptureSession.synchronizationClock` 转到 `CMClockGetHostTimeClock()`；随后把原始 IMU 插值到实际 MOV 视频帧时间。这一步已有明确时钟转换，不依赖录制按钮按下的墙上时间；但起始 PTS 是否对应首个**视频** buffer 仍待实测。
- `AVCaptureDevice.exposureDuration` 是读取时的设备状态。现有逐帧 K 回调里采样它，不能据此断定该帧真实曝光开始或结束时刻。Apple 的 `setExposureModeCustom` 完成回调提供首次生效视频 buffer 的设备时钟时间；诊断版已加入该时间转会话时钟与 host 时钟的日志。
- Gyroflow Proto 的官方时间定义以 readout latch 为帧端点，曝光中心 = latch − 曝光时间/2；当前 GyroCine Proto 通过估计的 latch 令曝光中心等于 MOV PTS。Sony MOV 的现有 IMU 轨未写入逐帧曝光时间。不能把 Proto 约定直接推断为 Sony MOV 解析器的时间原点。

参考：[Apple capture synchronization clock](https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock)、[CoreMotion timestamp](https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp)、[Apple custom exposure completion timestamp](https://developer.apple.com/documentation/avfoundation/avcapturedevice/setexposuremodecustom%28duration%3Aiso%3Acompletionhandler%3A%29)、[Gyroflow Proto 时间定义](https://github.com/gyroflow/docs.gyroflow.xyz/blob/main/technical-details/gyroflow-protobuf.md)。

## iPhone 18 Pro Max／H.265 4K60 实测

原始用户片段已复制到 Mac 的临时诊断目录，未修改手机中的 MOV。分析脚本：`tools/analyze_imu_sync.py`，用逐帧画面特征估计画面旋转速率，与 Sony MOV 内嵌 gyro Z 曲线按时间偏移做相关性搜索。该数值是光学估算，受取景深度、滚动快门与运动形态影响。

| 片段 | 曝光／对焦 | 视频 | IMU | 画面旋转与 gyro Z 最佳相关性 | gyro 相对画面延后 |
| --- | --- | --- | --- | --- | --- |
| `A001_10181240_C006.mov` | 约 1/120 秒，自动曝光／连续 AF | 461 帧、7.687 秒，最大帧间隔 18.33 ms、估计缺帧 0 | 769 组，最大原始采样间隔 9.96 ms | 0.9997 | 约 4 ms |
| `A001_10181245_C007.mov` | 约 1/60 秒，手动锁定曝光／对焦锁定 | 465 帧、7.753 秒，最大帧间隔 18.33 ms、估计缺帧 0 | 776 组，最大原始采样间隔 9.96 ms | 0.9994 | 约 3 ms |
| `A001_10181257_C008.mov` | 约 1/2004 秒，手动锁定曝光／连续 AF | 357 帧、5.953 秒，最大帧间隔 18.33 ms、估计缺帧 0 | 596 组，最大原始采样间隔 9.96 ms | 0.9994 | 约 6 ms |
| `A001_10181306_C009.mov` | **1×**，约 1/60 秒，手动曝光／对焦锁定 | 326 帧、5.435 秒，最大帧间隔 18.33 ms、估计缺帧 0 | 544 组，最大原始采样间隔 9.96 ms | 0.9985 | 约 −5 ms |
| `A001_10181306_C010.mov` | **1×**，约 1/2506 秒，手动曝光／对焦锁定 | 402 帧、6.700 秒，最大帧间隔 16.67 ms、估计缺帧 0 | 670 组，最大原始采样间隔 9.96 ms | 0.9995 | 约 +6 ms |
| `A001_10181314_C011.mov` | **1×**，约 1/60 秒，连续 AF | 182 帧、3.035 秒，估计缺帧 0 | 304 组 | 0.9997 | 约 −5 ms |
| `A001_10181315_C012.mov` | **1×**，约 1/60 秒，连续 AF | 243 帧、4.052 秒，估计缺帧 0 | 406 组 | 0.9999 | 约 −3 ms |
| `A001_10181315_C013.mov` | **1×**，约 1/2000 秒，对焦锁定 | 230 帧、3.833 秒，估计缺帧 0 | 384 组 | 0.9999 | 约 +4 ms |
| `A001_10181316_C014.mov` | **0.5×**，约 1/60 秒，对焦锁定 | 275 帧、4.585 秒，估计缺帧 0 | 459 组 | 0.9997 | 约 +1 ms |
| `A001_10181316_C015.mov` | **0.5×**，约 1/2004 秒，对焦锁定 | 296 帧、4.935 秒，估计缺帧 0 | 494 组 | 0.9996 | 约 +7 ms |

第二段日志在录制开始及录制中持续读到曝光 0.016665 秒、`exposureMode=custom`、`focusMode=locked`。两段都有 HEVC、AAC 与 Sony RTMD；全部视频帧已在 Mac 上解码用于光学分析。1/60 与约 1/120 的最佳偏移接近，当前证据不支持直接加入随曝光时间变化的固定半曝光补偿。两段的对焦及曝光控制不完全一致，且各只有约 8 秒；精度结论仍需同条件重复拍摄。

以 2.5 秒分窗，第一段的最佳偏移均为约 4 ms，第二段约为 2–3 ms；但相关性距峰值 0.001 内的偏移范围通常宽约 14–16 ms。因此这两段只能说明没有明显的大幅错位，不能把 1 ms 的表面差异当作真实曝光效应。

第三段的日志在录制开始与整段录制中均显示 `exposureDuration=0.000499 s`、`exposureMode=custom`、ISO 3600。全部 357 帧可解码；分窗最佳偏移约 4–7 ms，近峰范围跨过 0–15 ms 与 −5–13 ms。它同样未显示明显的曝光依赖错位，但对焦是连续 AF，不能与第二段视为完全受控的单变量对照。

前三段（均为 0.5×）的画面旋转／gyro Z 相关曲线共同拟合时，固定偏移峰值在约 **+4 ms**，平均相关性 0.999453；允许偏移随曝光时间线性变化后，最佳相关性仅增加 0.000019。固定模型的近峰范围约 −3 至 +12 ms，尚不能精确标定 +4 ms，也不能排除零偏移。仅看这三段时，近似固定偏移更符合测量结果。

**1× 新证据修正了上述判断。** C009 与 C010 使用同一 Format [59]、锁定对焦、60fps，实际曝光分别为 0.016666 与 0.000399 秒；两段的捕获时钟转 host 时钟差均约 0.4–0.5 ms，无法解释约 11 ms 的光学偏移差。固定偏移联合拟合相关性为 0.998500；拟合 `偏移 = 常数 − 曝光时间/2` 得 0.998921，已接近各段独立最佳拟合的 0.998963。模型的 1× 常数约 +5 ms，对两段预测约 −3.3 与 +4.8 ms。这个结果与“视频 PTS 接近读出锁存时间，画面代表曝光中点”一致，但仍可能受滚动快门、运动类型与光学估计误差影响。不要把前三段 0.5× 的固定偏移结论外推到 1×。

上述分析阶段未修改生产时间。随后按用户要求增加了下面的曝光字段实验；Release 保留原有 PTS 中心约定，Debug 可显式启用估计曝光结束模型。

### 首帧与 IMU 双传感器时间核查

- H.265／MovieFileOutput 路线将 `didStartRecording(... startPTS ...)` 经 `session.synchronizationClock` 转为 host 时间，作为 MOV 首个视频帧的零点。Apple 对 `startPTS` 的定义是“写入文件的第一个 buffer 的时间戳”，并未限定该 buffer 一定来自视频；因此安排了下面的七次独立视频／音频回调对照。最终封装以 MOV 实际首个视频帧 PTS 为相对零点，单看已归零的 MOV PTS 无法反推出录制前的绝对 host 时间。[Apple delegate 文档](https://developer.apple.com/documentation/avfoundation/avcapturefileoutputrecordingdelegate/fileoutput%28_%3Adidstartrecordingto%3Astartpts%3Afrom%3A%29)。
- C014/C015 的 `hostTime(startPTS) - startPTS` 分别为约 −0.430／−0.464 ms，相差仅 0.034 ms，时钟转换本身不能解释两段约 6 ms 的光学偏移差。此数值**不检验** `startPTS` 与首个视频 buffer 是否相同。
- `IMURecorder` 从 gyro 和 accelerometer 分别记录各自的 `sample.timestamp`；Sony MOV 在统一时间点各自线性插值后打包，没有直接按回调先后配对。两份保留原始 IMU 的本机日志（`IMG_0032`、`IMG_0033`）分别有 766／766 与 792／793 个 gyro／accel 样本；最近邻两类时间戳差均为 0 ms，最大采样间隔约 9.961 ms、无大于 30 ms 的间隙。这只证明这两次的标注时间与节拍，不排除传感器内部物理延迟；本轮光学对齐只使用 gyro，accel 相位不会造成观测到的 gyro 偏移。
- 后续受控录制继续保留 RAW IMU 和逐帧视频回调日志；下面七次短录先检验 `startPTS` 与独立视频／音频回调的对应关系，再决定是否需要更侵入的逐帧文件输出追踪。

### 首帧真机诊断：七次 H.265 4K60（iPhone 18 Pro Max）

用 `--first-buffer-probe` 只在 Debug 下复用现有 K 视频回调，并临时增加 AudioDataOutput 读取音频 buffer 时间戳；回调不读取或复制媒体负载。每次在 `MovieFileOutput.startRecording` 前开始采样，`didStartRecording(...startPTS...)` 后约 350 ms 汇总。四次 0.5× Format [57]、三次 1× Format [59]，每段自动录制约四秒。所有七次录制均收到 `didFinishRecording` 且其自己的 IMU 恢复任务完成。启动日志里的旧 `IMG_0028` SSD 恢复失败与本次测试文件无关。

| 镜头 | 录像数量 | `startPTS` 与视频回调最近 PTS | 与对应 K 回调 host 时间的最大差 | 第一个不早于 `startPTS` 的音频 buffer 延后 |
| --- | ---: | ---: | ---: | --- |
| 0.5× | 4 | 四次均精确相等（记录精度内 0 ms） | 0.006 ms | 15.93、13.02、10.36、15.33 ms |
| 1× | 3 | 三次均精确相等（记录精度内 0 ms） | 0.003 ms | 21.15、1.94、14.97 ms |

两段抽样拷回的原始 MOV（0.5× 与 1× 各一段）首个视频包 PTS 均为 0，分别有 244／246 个视频帧，AAC 音轨与 Sony RTMD 轨存在；首个 AAC 压缩包可带约 −44 ms 的编码预卷时间。这两段保留的原始 gyro 与 accel 均逐样同时间戳、相邻样本最大间隔约 9.96 ms。**七次观察中 `startPTS` 都对应视频 buffer，未观察到把音频 buffer 当作视频首帧的错位。**此诊断使用了额外的只读 AudioDataOutput，不能证明所有配置都如此；但这条首帧假设已不适合作为本轮 6–11 ms 偏移差的主要解释。生产时间戳逻辑未改动。原始日志与两段抽样 MOV 留在 `/tmp/gyrocine-imu-sync-20261018/`。

### 新增四组对照复核

手机新增 C011–C015 共五段。C011、C012 为 1×／1/60 的连续 AF 重复片段；其录制期间镜头位置发生变化，不能作为锁焦单变量对照。C013 为 1×／1/2000 且锁焦，位置保持 0.70588。C014、C015 是同一 0.5× Format [57]、60fps 且锁焦的有效成对对照，两段的镜头位置均保持 0.80392，录制期间无镜头位置变化事件。五段均完整解码，最大视频帧间隔不超过 18.34 ms，未检出大于标称帧间隔 1.5 倍的缺帧间隙；IMU 相邻采样约 10 ms。

锁焦的 0.5× 对照，1/60 秒的最佳光学偏移为 **+1 ms**，1/2004 秒为 **+7 ms**，相差 6 ms；两段曝光半时长差约 8.1 ms。1× 前一组同样锁焦的 C009/C010 差为 11 ms，方向一致。1× 新录的 C011/C012（连续 AF，1/60）为 −5/−3 ms，C013（锁焦，1/2000）为 +4 ms；因对焦条件不同，只作辅助参考。每段相关性约 0.999，峰值附近 0.001 相关性容差内的时差范围仍约 13–16 ms，因此现有证据支持曝光中心效应的趋势，但还不足以把 6–11 ms 差异定成精确补偿值。

## 曝光字段写入与补偿实验

用户授权在缺少更精确硬件时序的情况下写入估计元数据，并观察效果。本次实现：

- Sony RTMD 改为每个实际视频帧一个 packet，包内承载原来全局约 100 Hz 网格上的 IMU 向量；120fps 时允许某帧没有 IMU 向量，禁止伪造额外采样。曝光补偿条目与视频帧一一对应。
- 每帧写入 `e40c` 首行锁存相对时间、`e40d` 采样曝光时长、`e40e` 读出时长，以及 gyro／accel 各自的包内起始偏移和微秒时基。`e40e=0` 是未知读出时长的明确建模占位值，**不是硬件测量，也不由 1/FPS 推算**。文件 `rmin` 注明模型、曝光来源和估计状态。
- `presentationMidpoint` 保留旧约定：首行锁存偏移取曝光时长一半，Gyroflow 导出偏移约 0；`estimatedReadoutEnd` 假设 PTS 是首行曝光结束，锁存偏移取 0，Gyroflow 导出偏移约 `−曝光时长/2`。不另行平移原始 IMU，避免重复补偿。
- Proto 同样保留逐帧曝光时长，采用所选模型写入首末行锁存时间。两端相同表示当前零读出模型；未声称取得真实滚动快门时序。
- `PendingIMUJob` 保存模型选择，后台恢复沿用原录制约定；老任务缺字段时恢复基线约定。Debug 参数 `--exposure-timing-experiment` 启用并保存试验选择，`--disable-exposure-timing-experiment` 恢复基线；Release 忽略该 Debug 偏好。实验录像在 Log 保留原始 IMU／K。

### 已执行验证

1. 三个序列化／消费端时序／恢复兼容性单元测试通过；Debug 真机编译与 Release 编译通过。
2. 用生产 Swift 序列化器及 MOV 追加器，对 C009/C010/C014/C015 制作基线与实验两套副本。Gyroflow 1.6.3 成功解析：326／402／275／296 个曝光偏移与各自视频帧数一致，544／670／459／494 个 IMU 样本的向量与时间轴均和原文件一致。C014 原始与两套副本的压缩视频 SHA256 一致，未重新编码。
3. 1/60 秒实验补偿约 −8.34 ms，约 1/2506 与 1/2004 秒实验补偿约 −0.20／−0.25 ms；基线偏移不超过 0.001 ms。没有检测到双重曝光补偿。
4. 真实 120fps 的合成 MOV 经 Gyroflow 解析得到 60 个曝光偏移及 50 个 IMU 样本，空 IMU 帧保持正常。此项验证元数据消费兼容性，**不代表相机 120fps 真机录制验收**。
5. 官方 Proto 解码器与当前本机 Gyroflow Nightly 成功读取两套 Proto 副本：均为 326 帧、544 个 IMU 样本；基线首帧中心为 0，实验首帧中心为 −8.333 ms。
6. iPhone 18 Pro Max／1×／H.265 4K60 动态曝光真机录制 `UITEST_IMG_2026-10-18-14-13-26.mov`：14.605 秒、876 视频帧、876 个 Sony 曝光 packet、1461 个 IMU 样本、AAC 轨存在，录制正常完成、IMU 追加约 0.188 秒。录制中按 1/240 → 1/120 → 1/60 更改曝光，Gyroflow 解析出对应约 −2.084 → −4.168 → −8.336 ms 的偏移（初始曝光另有约 −0.403 ms）。
7. 同机同镜头 H.265 4K60／Proto 真机录制 `UITEST_IMG_2026-10-18-14-19-08.mov`：4.1 秒、246 视频帧、246 个 Proto packet、414 个 IMU 样本、AAC 存在；约 0.071 秒完成追加。Gyroflow Nightly 检出 `Apple iPhone19,7` 并读取全部 246 个逐帧曝光补偿和 414 个 IMU 样本。

### A/B 光学结果：写入成功不等于同步精度已经改善

在同一段原始图像运动和完全相同 IMU 上，只改变 Gyroflow 的每帧曝光偏移，比较画面旋转与 gyro Z 的相关性：

| 片段 | 曝光 | 基线相关性 | 零读出／减半曝光模型相关性 | 观察 |
| --- | --- | --- | --- | --- |
| 1× C009 | 1/60 | 0.998075 | 0.998330 | 略升 |
| 1× C010 | 约 1/2506 | 0.998918 | 0.998882 | 略降 |
| 0.5× C014 | 1/60 | 0.999694 | 0.998278 | 下降 |
| 0.5× C015 | 约 1/2004 | 0.998967 | 0.998920 | 略降 |

因此不能把零读出／减半曝光模型作为通用已校准修复。未知读出时间、传感器与视频链路的固定延迟仍可能贡献镜头相关常数；下一轮要把这些与曝光项联合验证。当前实验仅用于观察，正式版本仍保留原有 PTS 中心约定，同时交付完整曝光字段。负的首帧曝光中心还会超出当前从 0 开始的导出 IMU 区间，Gyroflow 会在边界取值；原始预录 IMU 保留在 Log，此项边界尚未通过 Sony 轨保留负时间实现。

副本、消费端解析结果、光学对照及临时生产序列化器宿主在 `/tmp/gyrocine-exposure-timing/`。手机原始用户素材未修改。

## 下一轮验收

1. 在 1× 和 0.5× 分别保持同一物理镜头及 Format、**锁定对焦与镜头位置**，补拍 1/120 和 1/240；每段 10–15 秒，连续小幅旋转并取有纹理的远景。1× 的 1/120 模型预测光学偏移约 +1 ms，是区分固定偏移与半曝光模型的关键中间点。ISO 按亮度适配并记录实际值。
2. 每段核对完整解码、实际 MOV PTS、原始 IMU 采样间隔、Sony 轨时间，再做多窗口光学相关与 Gyroflow Auto Sync。比较最佳偏移随曝光时间的变化及置信范围。
3. 只有多段数据出现稳定、可重复的偏移规律时，才修改生产封装时间。若最佳偏移与曝光无关，保留现有时间基准，并研究镜头读出与 Gyroflow 镜头配置。

诊断版的自动曝光切换测试因录制被提前停止，只得到一个 1/240 秒生效回调样本；未用于光学结论。该回调的输入时钟转 host 时钟成功，首次生效时间比 MOV 首帧 host 时间晚约 1.701 秒。


## 逐帧曝光信息统一接入（用户验证后）

用户反馈新录素材的逐帧曝光信息有用，要求应用到其他配置。新录像统一采用 `estimatedReadoutEnd`，Debug／Release 不再依赖实验偏好；Sony MOV 与 Gyroflow Proto 都交付逐帧曝光时长及零锁存偏移，由 Gyroflow 执行一次半曝光中心调整。Apple PTS 的物理曝光相位和传感器读出时长仍未测量，不能视为所有机型的时序校准。

代码覆盖路径：

| 录制路径 | 曝光采集 | 统一封装入口 |
| --- | --- | --- |
| H.265／HQ + 内部／专用／SSD | VideoDataOutput 元数据回调读取设备曝光状态 | didStart → PendingIMUJob → MovieIMUFinalizer |
| RAW／HQ + 专用／SSD（AssetWriter） | RAW buffer 回调 recordNativeMetadata 读取设备曝光状态 | started → 同一 didStart → 同一恢复任务／封装器 |
| 仍使用 MovieFileOutput 的 RAW 路径 | 现有内参元数据回调 | 同一恢复任务／封装器 |

镜头、分辨率、帧率、横竖方向不再控制该模型开关；按实际 MOV 每帧 PTS 对齐曝光证据。缺失的曝光证据仍可能插值或采用邻近值，来源会在元数据中注明，不能宣称是传感器逐帧曝光硬件测量。新任务持久化该模型；旧恢复任务缺模型字段时仍沿用旧约定，已有文件不批量改写。

新增回归覆盖：Sony／Proto 在 24、25、29.97、30、50、59.94、60、120fps，1080p／4K／RAW 4K／Open Gate 尺寸下序列化多种动态曝光时长；验证曝光字段及单次中心换算。这是封装层覆盖，不等于以上所有组合的新增真机录像／光学同步验收。

本轮结果：`ExposureTimingTests` 5 项通过，0 失败（含 8 种帧率 × 4 种尺寸 × 3 种曝光的双格式字段验证）；Debug 真机及 Release 编译通过。已更新安装到连接的 iPhone 18 Pro Max，保留原素材。本轮没有新增手持运动录像或完成所有 RAW／SSD 组合真机采集，逐配置实际增稳效果仍需后续验证。

以上“统一接入”决定取代前文“Release 保留旧模型／实验开关启用”的当时状态；前面的离线相关性记录仍仅代表历史分析指标。


## RAW 首帧起点专项核对

本轮复核录制代码和两段已有 RAW Open Gate 60fps 文件，没有新增手持运动采集。

- H.265：MovieFileOutput 的 delegate `startPTS` 经 session 同步时钟转 host。
- RAW AssetWriter：跳过编码器准备帧后，取首个待写视频 buffer 的原始 PTS，同时调用 `startSession(atSourceTime:)` 和 `started(pts)`；CameraManager 复用 didStart 处理函数仅为共用恢复任务逻辑，参数来源并非 MovieFileOutput。该视频 buffer 随后进入 FIFO，append 不重写时间；append 失败会报错，不会静默改用后续帧。
- 起点不使用首个预览帧、首个音频包或回调到达时刻。RAW 元数据和锚点都用 session 同步时钟转换到 host。
- 既有 `UITEST_IMG_writer_D2BC281B-7241-4EFD-961F-8DCC2527EE29.mov`：RAW started PTS 与传入共用 didStart 的 PTS 一致，首 K host 与 IMU 锚点差 0；605 个视频包、605 个 K 记录、MOV 首 PTS=0。
- 既有 `UITEST_IMG_writer_9F0B4DBB-48D4-4C71-9676-8FB8BFC76F9D.mov`：同样 PTS 一致，首 K host 与锚点差约 1ns；601 个视频包、601 个 K 记录、MOV 首 PTS=0。
- 两文件逐帧相对 MOV 时间与 K host 时间最大差分别约 0.840／0.841ms；视频轨 time_base=1/600，具有约 1.667ms 的存储时间刻度。残差与该量化尺度相符，但不作为独立时钟或曝光相位校准。当前没有看到整帧首帧错位；提高 RAW MOV 时间刻度可作为后续精度优化，不能用本次结果宣称曝光中心物理时序已经验证。

复核结果 `/tmp/gyrocine-raw-startpts-audit.json`。本次未改动录制链路代码。


## RAW MOV 时间刻度提升

在 `AVAssetWriter.startWriting()` 之前设置 `movieTimeScale=1_000_000`，并在视频输入上设置 `mediaTimeScale=1_000_000`。音频输入保留系统按采样率确定的时间刻度（Apple SDK 明确禁止音频输入设置非零 mediaTimeScale）。原始视频 buffer PTS、session 起点和 IMU 时间戳都不平移，不另行重采样或重编码。此项同时覆盖 RAW／HQ 的专用存储和 SSD Writer 路径；MovieFileOutput 的 H.265 路径没有改动。

增加每次录制一次的 `raw_writer_first_appended_video` 诊断，核对首个成功 append 的视频 PTS 是否等于 sessionStartPTS；encoder_ready 同时记录实际设置的 movie/videoTimeScale。提高的是文件时间刻度精度，无法消除曝光物理相位和传感器链路的未知延迟。

### 本轮真机验证结果

iPhone 18 Pro Max，1× RAW 4224×2240／60fps／专用视频存储，短录 `UITEST_IMG_writer_0119DEA4-4977-4868-8242-C03A6DA6CC8F.mov`：

- 125 个视频帧／125 个元数据帧，captureDrops=0，录制和 IMU 封装成功；首个成功 append 视频 PTS 与 startSession PTS 差 0。
- ffprobe 确认视频轨 time_base=`1/1000000`；直接解析 mvhd 确认 movieTimeScale=`1000000`；首视频 PTS=0。
- 完整硬件解码退出码 0；Gyroflow 1.6.3 读取到 209 个 IMU 样本及 125 个逐帧曝光偏移。
- MOV 相对 PTS 与 K 记录的 host 相对时间最大差 21.917µs。本轮检查脚本最初把两时钟域相对时间差也要求 <2µs，该假设未通过；随后确认文件两级时间刻度均已正确提高。host 映射结果还包含每次 session→host 时钟转换的变化，不能把文件 1µs 分辨率当成实测同步精度。本次没有把这约 22µs 的差值作为固定补偿写入。
- Debug／Release 构建通过。已安装并正常无参数启动，自动录制模式已退出；原素材保留，未重新编码已有视频。

结果及拷回测试片位于 `/tmp/gyrocine-raw-timescale/`。仅本配置完成新增真机验证；RAW HQ、SSD 同用设置入口，未为本次时间刻度变更逐一新增采集。
