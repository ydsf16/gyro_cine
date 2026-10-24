# 格式矩阵与 MOV 元信息审计 · 2026-10-24

状态：基线 748/748 完成；两处问题已修复，定向回归完成。

## 范围
- iPhone 17 Pro / iOS 26.0.1，主摄，内部文件，SonyMov，关闭 LUT 预览与烧录。
- 6 个可内录编码：H.265、H.265 HQ、ProRes 422 HQ / 422 / LT / Proxy。
- 界面可选尺寸：1920×1080、1920×1440、3840×2160、4032×3024（Open Gate）。
- 逐项枚举受支持的 Rec.709 / HDR / P3 D65 / Apple Log / Apple Log 2 与整数、分数帧率，共 748 组。
- 每组 3 秒，不能代替长录、热稳定性、运动同步或 Gyroflow 实际导出验收。
- RAW / RAW HQ 缺少 SSD，当前 iOS 26 无应用的专用存储录制路径，未列入实录通过数。其他镜头、SSD、专用存储及 GyroflowNightly 容器不属于本轮矩阵。

## 校验项目
1. 请求规格与输出编码、尺寸、实际帧率、活动色彩空间一致。
2. AVAssetReader 逐帧解码完成，帧数一致；检查最大帧间隔及缺帧数。
3. 音轨存在，并保留音频格式、采样率、声道信息。
4. 最终 MOV 中 IMU 存在；rmin 的 K 帧数与视频一致，记录相机/镜头、方向、曝光模型与采样间隔。
5. MOV 创建时间、色彩扩展、位深、场记、标准 make/model/software/creationdate 标签。

## 自动化
- Debug 启动参数：`--format-matrix --ssd-matrix --ssd-duration=3 --ssd-verify-decode`。
- 首批可用 `--matrix-limit=6`；续跑用 `--matrix-start-index=N`，均不影响 Release。
- 必须显式指定内部存储、SonyMov、关闭 LUT 烧录，并打开诊断。
- 手机证据：Documents/Log/format-matrix，含 plan/progress、每组 JSON 和最终 moov。
- 主机监控：`python3 tools/run_format_matrix.py --device UDID --output /tmp/gyrocine-format-matrix`。
- 审计：`python3 tools/audit_format_matrix.py /tmp/gyrocine-format-matrix --output /tmp/matrix-audit.json`。
- 仅删除本批生成且已逐帧解码的 UITEST_IMG_ 视频，保留诊断和最终 MOV 头。失败视频保留。

## 初步元信息结论
- 创建日期存在 MOV 文件头中（UTC）；缺少带时区的标准 QuickTime creationdate 文本标签。
- 机型、镜头名称位于 rmin / lens_profile；镜头名称较泛化（“后置相机”），不是精确的物理镜头/毫米焦距标签。
- 标准 QuickTime make/model/software 标签未写入。
- 场记字段仅在有值时写入，空导演/摄影师等不视为丢失。
- 曝光时间进入遥测；非 RAW 路径当前没有统一导出 ISO、白平衡、光圈、专业 tmcd 时间码。Sony 兼容元数据中的焦距换算不能当作真实毫米焦距。
- 另行读取本机历史 RAW / RAW HQ 原片（C019 / C041）：标准 make/model、ISO、快门角度/时间、白平衡、场记均存在；这与 RAW writer 合并系统推荐元信息的代码一致。历史文件审计不等同本版本重新录制验收。

## 中途检查（完成 422 组时）
- 416 组通过文件检查；6 组保存、解码成功，但帧间隔显示缺帧，不能计为通过。
- index 301：ProRes 422 HQ / 4K60 / P3 D65，估算缺 2 帧，最大间隔 50 ms。
- index 336、337：ProRes 422 / 1080p119.88、120 / Rec.709，各缺 1 帧。
- index 366、367：ProRes 422 / 1080p119.88、120 / Apple Log，各缺 1 帧。
- index 376：ProRes 422 / 1080p119.88 / Apple Log 2，缺 1 帧。
- 已保留 JSON 和完整 moov 时间表。当前安装的测试程序在解码通过后删除测试 MOV；下一版已改为缺帧也保留 MOV，复测时使用。
- index 82：H.265 / 4K119.88 / P3 D65，视频不缺帧，368 帧 K 中 1 帧插值。
- 原矩阵继续执行；新增素材信息功能尚未安装，不改变本轮基线。

## 启动缺帧定位与待回归修复
- 当前已检查的 7 个失败样本，MOV 缺口都在 sample 0 之后，后续时间轴连续。
- 原始 camera_frames.jsonl 在同一窗口仍具有完整 60 / 120 fps 采样。例如 index 301 的原始偏移为 0.006、16.676、33.338、50.003 ms，而 MOV 首帧持续 50 ms。
- 原因：RealtimeLUTWriter 在 encoderReady=false 时允许第一个视频入队。若它排在 startWriting 后面，warmup 清理无法看见尚未执行的队列任务；后续等待帧被拒绝，但这个旧帧会成为首帧。
- 修复：音频初始化 writer 期间不接收视频；encoderReady=true 后的首个真实采集帧建立 startPTS。保留真实采集时间，未改变 IMU 对齐或规整掉真正丢帧。
- 准备新增 DEBUG 定向复测参数：matrix-run、matrix-indices、matrix-repeat、matrix-keep-movies；各次结果目录隔离。
- writer-startup-delay-probe 仅在 DEBUG 中人为延迟启动 100ms，用于回归上述竞态；Release 不包含该延迟。

## 基线最终结果
- 748 组全部生成文件、逐帧解码完成，带音频及 IMU；740 组通过全部文件检查。
- 8 组首帧后有时间缺口：301、336、337、366、367、376、517、646；最后一项为 ProRes Proxy / 1080p119.88 / Apple Log。没有把这些组计为通过。
- 完整基线证据：`/tmp/gyrocine-format-matrix`；仓库保留 `qa-evidence/2026-10-24-iphone17pro/matrix-baseline-cases.csv` 和 summary JSON。
- 首次修复版的 8 个失败配置各重复 3 次，24 次均通过，无首帧时间缺口。

## 额外发现：跨录制路径的尺寸恢复
- 定向回归两次出现 ProRes Proxy 1080p → H.265 4K119.88 封装失败，日志为“没有与 MOV 像素尺寸一致的有效 K 数据”。
- 录像本身正常停止；camera_frames 全程为 1920×1080，而 MOV 是 3840×2160。
- 原因：保存 intrinsicOutput.videoSettings 时，getter 带有当前解析出的宽高；录制结束恢复这个字典后，把旧尺寸变成了显式约束。
- 修复：恢复设置保留像素格式，移除宽高约束，让后续尺寸跟随活动采集格式。
- 初次 27 次复测中的这两次失败保留，不以复跑覆盖；证据见 startup-retest-before-dimension-fix.json 和 resolution-switch-failure.json。

## 修复后最终回归
- 最终构建：27/27 通过。覆盖 8 个原失败配置各 3 次，以及 H.265 4K119.88 P3 共 3 次。
- 包含两次不重启 App 从 ProRes Proxy 1080p 切回 H.265 4K；K 与视频尺寸匹配、IMU 封装成功，三次 H.265 K 插值帧数均为 0。
- 人为延迟编码器启动 100ms：4 种 ProRes 各 2 次，8/8 通过，未出现首帧缺口。
- 新元数据实录：6 种编码各一组，6/6 通过；标准标签、拍摄快照、双语备注、音视频、IMU/K、解码全部检查通过。
- 最终修改没有再次全跑 748 组；完整遍历为修复前基线，最终版本以以上针对性回归验证。
- 连续测试曾触发 serious 热状态，测试等待降温后继续。DEBUG 测试程序已在降温时停止采集，避免高帧率预览持续发热。
- Release 构建通过；完整审计数据在 /tmp/gyrocine-final-regression、/tmp/gyrocine-startup-stress、/tmp/gyrocine-metadata，仓库保留精简报告与证据。
