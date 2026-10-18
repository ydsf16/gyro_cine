# 2026-10-18 录制稳定性复测记录

执行依据：[RELEASE_RECORDING_STABILITY_PLAN.md](RELEASE_RECORDING_STABILITY_PLAN.md)。本文件随测试继续更新；未列为 PASS 的项目尚未验收。

## 本轮基线

| 项目 | 值 |
| --- | --- |
| 源码 | `a3bdc2e` + 未提交的本地化、UITest 和测试计划改动 |
| 安装的测试构建 | Debug，1.0 (20261017.3)；发版前仍需对最终 Release 候选构建复测 |
| 设备 | iPhone 18 Pro Max (iPhone19,7)，iOS 27.0.1 |
| Mac 调试连接 | `devicectl` 显示 `localNetwork`；USB 已拔下，SSD 接在手机 |
| 目标 SSD | App 显示 `tiny_grape`，约 2 TB；预检约 1.98 TB 空闲，测试后约 1.915 TB；文件系统类型尚未从系统读取 |
| 输出配置 | 预检截图时是 ProRes RAW HQ、4224×2240、60.0fps；存储选外部 SSD |

本轮结束已恢复 1×、ProRes RAW HQ、4224×2240、60.0fps、外部 SSD；无测试启动参数的重开截图 `/tmp/gyrocine-restored-persistent-screen.png` 再次确认。其他原有控制设置没有主动修改；自动测试生成的 SSD 原片与异常片均保留，未删除用户素材。

随后安装了包含剩余时间下限修正的同版本 Debug 构建；最终再次恢复相同的 1×／RAW HQ／4224×2240／60fps／SSD 配置，截图 `/tmp/gyrocine-final-restored-20261018.png`。安装是覆盖更新，未卸载。手机最后截图电池指示已变红，停止安排新的长录以免电量影响稳定性结论。

离线检查又将相同下限加入 SSD 测速规格表，避免暗场样本把建议持续写入速度压得过低。增量编译和覆盖安装成功；最新无测试参数启动截图 `/tmp/gyrocine-latest-build-restored-20261018.png` 再次显示原配置。规格表本身仍待真机 UI 操作验收。

续测发现英文设置页把已选存储位置显示为中文“外部 SSD”。已在 `SettingsView` 对该持久化值补英文显示映射，保持 UserDefaults 实际值不变。Debug 增量构建成功、Wi-Fi 覆盖安装后，真机截图显示 `External SSD`；不带测试参数重启后，原 1×／RAW HQ／4224×2240／60fps／SSD 配置与约 1861.6GB 可用空间仍显示正常。证据 `/tmp/gyrocine-settings-preview-20261018.png`、`/tmp/gyrocine-settings-storage-english-fixed-20261018.png`、`/tmp/gyrocine-after-settings-fix-ready-20261018.png`。测试入口直接打开 Settings，因未启动相机会暂时灰掉视频规格项；不能据此判定正常拍摄流程的选项不可用。

同一显示映射加入 `testEnglishSettingsAndSlate` 断言，在模拟器给定英文语言与“外部 SSD”持久化值时检查 `External SSD`；1 项通过、0 失败，结果 `/tmp/gyrocine-english-storage-regression-20261018.xcresult`。模拟器用例只证明文案映射与设置页控件，真机设置菜单交互仍未完成。

## A 阶段结果

| ID | 结果 | 证据 / 说明 |
| --- | --- | --- |
| 无线控制 | PASS | Wi-Fi `devicectl` 截图成功；XCTest `testExternalSSDWirelessPreflight` 真机通过，1 项 0 失败，截图保留 |
| A01 冷启动和配置 | PARTIAL | UITest 能打开 Settings，配置与 SSD 目标盘可见；前后台、重启配置及录制状态尚未验收 |
| A02 SSD 测速 | PASS（测量完成）/ 高风险（RAW 写入停顿） | 8.6 GB 临时数据测速完成，无 UI 错误。后半段最低 382 MB/s；全程平均 392 MB/s；最长写入停顿 555 ms；最长落盘 756 ms。截图中测速按钮已恢复，App 报告临时文件已清理；尚未独立检查盘上残留 |
| B01 SSD RAW 4K30 短录 | PASS | `IMG_0003.mov`，15.033 s、451/451 帧完整解码，平均 30.000fps，最大 PTS 间隔 33.33ms，估计缺帧 0，音频 1 轨、内嵌 IMU；1.76 GB |
| B02 SSD RAW HQ 4K60 短录 | PASS（15 秒）/ 长录高风险 | `IMG_0004.mov`，15.023 s、901/901 帧完整解码，平均 59.973fps，最大 PTS 间隔 18.33ms，估计缺帧 0，音频 1 轨、内嵌 IMU；5.31 GB。平均文件增长约 354 MB/s，按测速界面 30% 余量规则需约 460 MB/s，超过本轮 382 MB/s 的后半段最低速度；不据此宣称长录稳定 |
| A03 H.265 4K60 | PASS（两种存储各 15 秒） | SSD `IMG_0005.mov`：15.09 s、905/905 帧完整解码、最大间隔 18.33 ms、0 估计缺帧、音频及 IMU；内部 `UITEST_IMG_2026-10-18-00-23-00.mov`：15.057 s、903/903 帧，其余检查相同 |
| A04 专用存储 RAW 4K30 | PASS（5 秒） | PVS 绿色，容量约 150→149.3 GB；`UITEST_IMG_writer_A6371223-D78C-42F1-86FD-E69C33897C55.mov`，5.033 s、151/151 帧完整解码、最大间隔 33.33 ms、估计缺帧 0、音频一轨、内嵌 IMU，692 MB。Wi-Fi 文件服务恢复后取回结果；截图 `/tmp/gyrocine-dedicated-raw-screen.png`。 |
| Media 读取已连 SSD | PASS（列表与状态） | 无线 `devicectl` 以 Debug 参数 `--show-media-diagnostic` 打开素材页；截图可见 SSD 上 `IMG_0016` 至 `IMG_0022` 等测试片的时长、大小、RAW 标记。合格片显示绿色 `IMU`，已知无内嵌 IMU 的 `IMG_0019`、`IMG_0022` 显示红色 `!IMU`。截图 `/tmp/gyrocine-ssd-media-20261018.png`。尚未验证点击播放、选择/删除/分享；随后不带测试参数重新启动，原 1×／RAW HQ／4224×2240／60fps／SSD 设置仍在，截图 `/tmp/gyrocine-after-media-restored-20261018.png`。 |

## B 阶段：1× SSD RAW 短录矩阵

| 编码 / 尺寸 / FPS | 结果 | 文件、时长、帧数、最大间隔、大小 |
| --- | --- | --- |
| RAW / 4224×2240 / 30 | PASS | `IMG_0003.mov`；15.033 s；451/451 帧；33.33 ms；1.76 GB |
| RAW / 4224×2240 / 60 | PASS（15 秒） | `IMG_0006.mov`；15.073 s；904/904 帧；18.33 ms；4.22 GB |
| RAW HQ / 4224×2240 / 30 | PASS | `IMG_0007.mov`；15.033 s；451/451 帧；33.33 ms；2.62 GB |
| RAW HQ / 4224×2240 / 60 | PASS（15 秒）/ 长录高风险 | `IMG_0004.mov`；15.023 s；901/901 帧；18.33 ms；5.31 GB |
| RAW / 4224×3024 / 30 | PASS | `IMG_0008.mov`；15.067 s；452/452 帧；33.33 ms；2.37 GB。452 个真实逐帧 K 全部有效且时间单调；IMU 3101 条，两类传感器各自单调，覆盖 K 首尾前至少 184ms、后至少 210ms |
| RAW / 4224×3024 / 60 | PASS（15 秒）/ 长录高风险 | `IMG_0009.mov`；15.023 s；901/901 帧；18.33 ms；5.64 GB。901 个真实逐帧 K 全部有效且时间单调；IMU 3109 条，两类传感器各自单调，覆盖 K 首尾前至少 192ms、后至少 269ms |
| RAW HQ / 4224×3024 / 30 | PASS（15 秒） | `IMG_0010.mov`；15.033 s；451/451 帧；33.33 ms；3.54 GB |
| RAW HQ / 4224×3024 / 60 | **FAIL：保护停录** | `IMG_0011.mov` 在约 15 秒内出现 17 个 `OutOfBuffers` 丢帧；5 秒窗口累计 17 帧时主动停录。原始 MOV 6.996 GB 与 `failed-imu.json` 保留，未内嵌 IMU，不计合格片段。系统压力 nominal、thermalState 0、峰值视频缓冲 4 帧，最大回调 214 ms。SSD 速度 382 MB/s，文件增长约 466 MB/s，容量约 1.69 TB，并非容量不足。App 显示存储速度/丢帧错误，仍需验证不重启再录能力。 |
| RAW / 4224×2240 / 120 | **FAIL：录制中保护停录** | 格式 68 可配置、Writer 开录；`IMG_0019.mov` 在受控约 10 秒录制中出现 123 次 `OutOfBuffers`，Writer 主动结束。约 4.85 GB 原片和 `failed-imu.json` 保留，不计合格片段。系统压力 nominal、thermalState 0；峰值缓冲 9 帧、最大回调 142.6ms。紧接着重开 App 后 RAW4K30 `IMG_0020.mov` 5.10s、153/153 帧、0 缺帧，音频/IMU 齐全；**同一进程内恢复尚未验证**。 |
| H.265 / 1920×1080 / 120 | PASS | `IMG_0021.mov`；15.122s、1814/1814 帧完整解码、平均 119.960fps、最大间隔 8.75ms、估计缺帧 0；音频和内嵌 IMU 齐全，2.87MB（暗场）。同次调试记录 1869 个真实 K 样本、3131 条 IMU 原始样本，覆盖约 15.58 秒；仍待 Gyroflow 导入确认。 |
| H.265 / 1920×1080 / 240 | 视频 PASS / Gyroflow N/A | `IMG_0022.mov`；10.057s、2413/2413 帧完整解码、平均 239.940fps、最大间隔 4.58ms、估计缺帧 0，音频轨齐全。此设备格式 42 未输出 K（内参回调 0 帧），最终 MOV 无内嵌 IMU；取景页明确显示红色 `!IMU!`，不能宣称可用于 Gyroflow 增稳。 |

上述 PASS 片段均含一条音频轨、内嵌 IMU、全帧解码完成且估计缺帧 0。高带宽两项短录通过不能外推为长录稳定；RAW HQ Open Gate 60 已明确失败，暂不重复该规格长录。逐项 JSON 位于 `/tmp/gyrocine-<case>-result-20261018.json`；异常日志及截图见下。

**逐帧 K / IMU 补查：** 经 Wi-Fi 从手机 `Documents/Log` 只读取回 `IMG_0003`～`IMG_0010` 的原始 K 与 IMU。八片所有 K 矩阵均为有限有效值、尺寸与 MOV 匹配、时间严格递增；角速度和加速度各自时间严格递增。七片 RAW 的 K 数量与视频帧数一一相等（451、901、904、451、452、901、451）；其 IMU 在 K 首尾前后均至少覆盖约 158ms / 201ms。H.265 `IMG_0005` 为 905 视频帧、948 个 K 回调，含录像范围外样本；其 IMU 未覆盖全部额外 K 回调，因此不能以全部 K 首尾作视频区间边界。该片已通过 MOV 内嵌遥测及 Gyroflow 导入，但具体光学时间同步仍待有运动的片段验证。

**小数帧率对照：** 1× RAW 4224×2240 选 29.97fps 录成 `IMG_0017.mov`（15.067s、452/452 帧、实际平均 30.000fps）；选 59.94fps 录成 `IMG_0018.mov`（15.023s、901/901 帧、实际平均 59.973fps）。两片全解码、估计缺帧 0、音频及 IMU 齐全。配置日志显示 `activeVideoMin/MaxFrameDuration` 和 RAW Writer `ExpectedFrameRate` 确实分别设置为 29.97/59.94，实际 MOV 帧时间却主要按 30/60 输出。**帧率精确性 FAIL**；需查传感器实际时间戳/系统是否将所选近似值量化，不能把这两项记作精确小数帧率通过。录制开始前准备阶段另有 1/3 个 `FrameWasLate` 通知，录制区间文件时间轴无缺帧。

## C 阶段：代表性长录

| 配置 | 结果 | 文件级证据 |
| --- | --- | --- |
| 1× RAW 4224×2240 30fps，SSD，5 分钟 | PASS | `IMG_0012.mov`，300.098 s、9002/9002 帧完整解码，平均 29.997fps，最大帧间隔 35.00ms、估计缺帧 0，音频一轨、内嵌 IMU，34.996 GB。封装完成后拍摄页回到 Ready。同次 9002 个 K 全部有效且时间单调；IMU 60331 条单调，覆盖 K 首尾前约 161ms、后约 218ms。 |
| H.265 4K60，SSD，5 分钟 | PASS（静态暗场） | `IMG_0013.mov`，300.073 s、17997/17997 帧完整解码，平均 59.975fps，最大间隔 18.33ms、估计缺帧 0，音频一轨、内嵌 IMU，89.1 MB。当前取景是暗场，压缩码率极低；帧率验收成立，但不能据此估计复杂场景文件大小。同次有 18038 个有效 K（含录制前后样本）；IMU 60392 条，角速度/加速度各 30196 条，各自时间单调。按录制起始 `firstHost` 与 MOV 时长估算，IMU 覆盖录制首尾前约 225ms、后约 456ms。原始混合 IMU 文件并非全局按时间排序；封装代码已按传感器类型分别排序并验证覆盖。 |
| 0.5× RAW 4224×2240 30fps，SSD，15 秒 | PASS | 物理镜头由 `built-in_video:0` 切到 `built-in_video:5`，格式 61；`IMG_0014.mov`，451/451 帧全解码、0 估计缺帧，音频与 IMU 齐全。 |
| 4× RAW 4224×2240 30fps，SSD，15 秒 | PASS | 物理镜头由 `built-in_video:5` 切到 `built-in_video:2`，格式 61；`IMG_0015.mov`，451/451 帧全解码、0 估计缺帧，音频与 IMU 齐全。 |
| 0.5× RAW 4224×2240 30fps，SSD，5 分钟 | PASS | `IMG_0016.mov`，300.040 s、9001/9001 帧完整解码，平均 29.999fps，最大帧间隔 35.00ms、估计缺帧 0，音频一轨、内嵌 IMU，41.665 GB。镜头选择为物理 0.5×，见短录切镜日志。同次记录 9001 个有效 K，时间单调且数量与 MOV 帧数一致；IMU 60349 条（加速度 30175、角速度 30174），单调，覆盖 K 首尾前约 283ms、后约 230ms。 |

### 本轮发现的问题

1. **RAW HQ Open Gate 60 + 当前 SSD：** 触发 `OutOfBuffers`，App 安全停录并保留异常原片，用户需降规格或换盘。实测文件增长约 466 MB/s 高于 SSD 测得的后半段最低 382 MB/s；此关联支持写入压力假设，但 `OutOfBuffers` 也可能来自采集缓冲池，尚未单独证实根因。
2. **H.265 剩余时间夸大：** 暗场长录后拍摄页显示“Free 1919.1 GB · ~119566 min”。本轮实际片段只有约 0.30 MB/s，显示算法将这种极低瞬时码率外推到全部剩余容量。需要设置合理下限或保守设备规格估计，不能让用户依此判断可录时长。截图 `/tmp/gyrocine-hevc-long-screen.png`。
3. **Wi-Fi XCTest / 文件服务不稳定：** `testSSDWriterBufferFailureThenRetry` 的 runner 等约四分钟才进入测试，随后卡在 `Launch com.tinygrape.RawMotionRecorder`，已人工结束；没有得到 App 断写恢复结论。之后 `devicectl` 截图可用，但 `appDataContainer` 下较大的日志和目录列表一度超时；尝试一次重启 Mac 当前用户 CoreDeviceService 后仍复现。后来文件服务自行恢复，已补取专用存储及 4× 日志；仍需重跑无线 UITest。驱动失败不算录像失败。
   最新构建已重新 `build-for-testing` 成功；无线 `testNativeSettingsMenusFullRow` 再次在测试方法执行前失败：runner code 74，`Connection peer refused channel request for dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface`。33.8 秒后退出，未操作设置。日志 `/tmp/gyrocine-wifi-settings-20261018.log`，结果 `/tmp/gyrocine-wifi-settings-20261018.xcresult`；不再连续重试同一连接故障。
   英文存储显示修正覆盖安装后，再次 `build-for-testing` 成功，但 `test-without-building` 启动前 Xcode 已不再列出 iPhone 18 Pro Max 作为可用 destination；随后 `devicectl list devices` 也将该机从 `connected` 变为 `unavailable`。本次没有启动 runner 或测试方法；日志 `/tmp/gyrocine-wifi-settings-retry-20261018.log`，构建日志 `/tmp/gyrocine-settings-retry-bft-20261018.log`。此时不再重试或重启连接服务，等待设备重新可用。
4. **29.97/59.94fps 实际帧率偏向整数值：** App 的帧时长/Writer 设置日志与所选小数值一致，MOV 帧时间实测接近 30/60。29.97 测试的 452 个相机 K 回调原始 `hostTime` 间隔中位数 33.334ms，接近 30fps 的 33.333ms，而非 29.97fps 的 33.367ms；偏差发生在相机送出的时间轴，早于 MOV 封装。还需查 AVFoundation 的设备格式限制，再决定修复方式或从 RAW 可选项中移除该档位。
5. **120fps + 当前 SSD 写入不足：** 10 秒短录出现 123 次 `OutOfBuffers` 并保护停录，原片无内嵌 IMU；约 4.85 GB/10 秒的文件增长也超过本轮测速 382 MB/s 后半段最低值。此设备支持该格式，但当前 SSD 组合不合格；暂不做长录。
6. **高风险规格缺少开录前提示：** `SSDSpeedTestView` 会将测速结果和规格建议速度比较并显示“有风险/不足”，但 `CameraManager.startRAWWriterExperiment()` 的开录路径只调用 `storagePreflight()`，未读取 `ssdSpeedReport.assessment`。因此即使已测速，用户选择 RAW HQ Open Gate 60 或 RAW 120 后仍可直接开录，随后才由丢帧保护停录。本轮可复核 `Sources/CameraManager.swift` 的开录路径与测速报告使用位置；这是发版前待修复的提示缺口，不能把测速页面的风险标记当作录制前保护已经生效。

H.265 暗场码率造成的剩余时间夸大已在工作区加入保守下限：显示估算至少按同配置保守速率的 25% 计算。Debug 构建已编译并通过 Wi-Fi 安装；同盘约 1861.6GB 空闲时，1080p240 暗场截图显示约 991 分钟，没有出现原先 119566 分钟的数量级错误。仍需按实际复杂场景核对估算偏差。

同配置 RAW HQ 4224×2240／60fps 的短片 `IMG_0004.mov` 实际增长 353.56 MB/s；以主界面后续显示的 1861.6GB 可用空间、约 5.68GB 录制保留量计算，约可录 87.5 分钟，与界面约 88 分钟相差约 0.6%。这只说明该格式基于本机已录样本的估算与该短片速率一致；不同画面、持续写入停顿和温度仍会改变实际可录时间，也不代表这块 SSD 满足 30% 写入余量。

离线/模拟器回归：`xcodebuild build-for-testing` 成功；使用仓库 `.venv/bin/python -m unittest discover -s tools -p 'test_*.py' -v`，9 项全部通过。模拟器 iOS 26.3 的 `GyroCineTests` 40 项通过；`testEnglishSettingsAndSlate` 和 `testNativeMenusWithoutCamera` 2 项通过，覆盖英文设置/场记及整行菜单点击。模拟器结果只用于纯逻辑/控件，不能代替实体相机/SSD/IMU 验收。系统 Python 缺少 `google.protobuf`，因此不能用其失败结果代替仓库虚拟环境的测试结论。

`testNativeSettingsMenusFullRow` 最初在模拟器失败于“H.265 HQ”选项不存在；模拟器无真实相机格式，不能据此判断真机菜单有缺陷。现已让此用例在模拟器明确 `XCTSkip`，重跑 1 项跳过、0 失败（`/tmp/gyrocine-fullrow-skip-sim-20261018.xcresult`）；仍待无线 XCTest 恢复后在 iPhone 18 Pro Max 上执行。

**解释：** 555 ms 比 60fps RAW 的 10 帧预算约 167 ms 长，也比 30fps 的约 333 ms 长。测速的停顿并不等于一定丢帧；它使高带宽配置必须先短录、查实际 MOV PTS 和 Writer 日志，再决定是否长录。382 MB/s 为本轮实测后半段最低值，不能替代具体编码/帧率的实际写入需求。

## Gyroflow 导入与导出抽检

从手机经 Wi-Fi 复制内部存储的 `UITEST_IMG_2026-10-18-00-23-00.mov` 到 Mac `/tmp/gyrocine-gf-qa-20261018.mov`，未改动手机原片。`ffprobe` 确认 3840×2160 HEVC、AAC、Sony RTMD 兼容数据轨及 Core Media 元数据轨，时长 15.057 秒。

Gyroflow v1.6.3 成功打开该 MOV，界面显示 59.973fps、`包含陀螺仪数据: Yes`、`Apple per-frame K` 镜头模型，并显示运动曲线。导出为 `/tmp/gyrocine-gf-qa-20261018_stabilized.mp4` 后，`ffprobe` 确认 H.264 3840×2160、903 帧、AAC、15.060 秒；`ffmpeg` 全片解码无错误。**导入、遥测识别、导出与解码 PASS。** 片段为暗场静态场景，不能据此判断自动同步精度或运动增稳效果；镜头面板仍显示 `Not calibrated`，虽然逐帧 K 模型已被识别。导出重新编码仅用于 Gyroflow 验收，不改变 App 原始 MOV 录制链路。

原片音频轨经独立检查为 AAC 48kHz 双声道；解码音频有非零信号，最大约 -47.4 dBFS、平均约 -60.4 dBFS。左右声道 722880 个样本的相关系数约 0.673、差分 RMS 约 0.000787，证实两声道并非完全相同的双单声道。该暗场片段环境很安静，数值检查不能代替主观抽听。

## 已遇到的测试工具问题

最初两次预检用例在已选 SSD 时再次展开存储菜单，XCTest 停在菜单交互；手机截图表明 SSD `tiny_grape` 已选。已中断这两次 runner，并修改预检用例，在已配置好的设备上直接进入测速。第三次用例通过。此问题按**测试脚本/界面交互问题**记录，不当作录制或 SSD 失败。前两次未开始测速，也没有生成本轮 MOV。

## 证据位置

- 通过的 XCTest：`/tmp/gyrocine-ssd-preflight-3-20261018.xcresult`
- 通过的测试日志：`/tmp/gyrocine-ssd-preflight-3-20261018.log`
- 结果截图：`/tmp/gyrocine-ssd-preflight-3-screens/91B60932-5C54-4A98-92AF-9580B5E2E5B6.png`
- 手机预检截图：`/tmp/gyrocine-ssd-preflight-20261018.png`
- RAW 4K30 文件级结果：`/tmp/gyrocine-ssd-raw30-result-20261018.json`
- RAW HQ 4K60 文件级结果：`/tmp/gyrocine-ssd-hq60-result2-20261018.json`
- 两段原始 SSD MOV：`DCIM/100APPLE/IMG_0003.mov`、`IMG_0004.mov`，保留未删除
- H.265 SSD / 内部核验：`/tmp/gyrocine-hevc-ssd-result-20261018.json`、`/tmp/gyrocine-hevc-internal-result-20261018.json`
- RAW 矩阵核验：`/tmp/gyrocine-{raw4k60,hq4k30,rawog30,rawog60,hqog30}-result-20261018.json`
- 八片短录 K/IMU 原始证据：`/tmp/gyrocine-img0003-camera_frames.jsonl`～`/tmp/gyrocine-img0010-camera_frames.jsonl` 及同编号 `imu_raw.jsonl`；原件仍在手机 `Documents/Log`
- Open Gate RAW 30/60 K 与 IMU 原始记录：`/tmp/gyrocine-img0008-camera-frames.jsonl`、`/tmp/gyrocine-img0008-imu-raw.jsonl`、`/tmp/gyrocine-img0009-camera-frames.jsonl`、`/tmp/gyrocine-img0009-imu-raw.jsonl`；均由手机 `Documents/Log` 经 Wi-Fi 只读复制，原件保留
- RAW HQ Open Gate 60 失败：`/tmp/gyrocine-hqog60-events-20261018.jsonl`、`/tmp/gyrocine-hqog60-failed-imu-20261018.json`、`/tmp/gyrocine-hqog60-failure-20261018.png`；SSD 上 `DCIM/100APPLE/IMG_0011.mov` 保留
- RAW 4K30 五分钟长录：`/tmp/gyrocine-raw4k30-long-result-final-20261018.json`；SSD 上 `DCIM/100APPLE/IMG_0012.mov` 保留
- 同片 K/IMU 原始范围：`/tmp/gyrocine-img0012-camera-frames.jsonl`、`/tmp/gyrocine-img0012-imu-raw.jsonl`；K 9002/9002 有效，IMU 首尾边界余量均超过 50ms
- H.265 4K60 五分钟长录：`/tmp/gyrocine-hevc4k60-long-result-20261018.json`；SSD 上 `DCIM/100APPLE/IMG_0013.mov` 保留
- 同片 K/IMU 与录制起点：`/tmp/gyrocine-img0013-camera-frames.jsonl`、`/tmp/gyrocine-img0013-imu-raw.jsonl`、`/tmp/gyrocine-hevc4k60-long-events-20261018.jsonl`
- 0.5×、4× RAW 15 秒：`/tmp/gyrocine-lens0p5-result-20261018.json`、`/tmp/gyrocine-lens4-result-final-20261018.json`；SSD `IMG_0014.mov`、`IMG_0015.mov` 保留
- 0.5× 物理切换日志 `/tmp/gyrocine-lens05-events.jsonl`；异常恢复 UITest 驱动日志 `/tmp/gyrocine-stability-retry-20261018.log`
- 4× 物理切换日志 `/tmp/gyrocine-lens4-events-final.jsonl`；专用存储 RAW 核验 `/tmp/gyrocine-dedicated-raw-result-final-20261018.json`
- 0.5× RAW 五分钟全片核验：`/tmp/gyrocine-ultrawide-raw5min-result-20261018.json`；SSD `DCIM/100APPLE/IMG_0016.mov` 保留
- 同片 K/IMU 原始范围：`/tmp/gyrocine-img0016-camera-frames.jsonl`、`/tmp/gyrocine-img0016-imu-raw.jsonl`；K 9001/9001 有效，IMU 首尾边界余量均超过 50ms
- 小数帧率结果及配置日志：`/tmp/gyrocine-raw4k2997-result-20261018.json`、`/tmp/gyrocine-raw4k5994-result-20261018.json`、`/tmp/gyrocine-raw2997-events.jsonl`、`/tmp/gyrocine-raw5994-events.jsonl`；SSD `IMG_0017.mov`、`IMG_0018.mov` 保留
- 29.97 相机原始 K 时间轴：`/tmp/gyrocine-img0017-camera-frames.jsonl`，452 个样本中位间隔 33.334ms
- RAW120 失败与降档复录：`/tmp/gyrocine-raw120-events-20261018.jsonl`、`/tmp/gyrocine-raw120-failed-imu-20261018.json`、`/tmp/gyrocine-raw120-screen-20261018.png`、`/tmp/gyrocine-after120-raw30-result-20261018.json`；SSD `IMG_0019.mov` 失败原片与 `IMG_0020.mov` 合格短片均保留
- H.265 高帧率与估算 UI：`/tmp/gyrocine-hevc1080p120-result-20261018.json`、`/tmp/gyrocine-hevc1080p240-result-20261018.json`、`/tmp/gyrocine-hevc240-events-20261018.jsonl`、`/tmp/gyrocine-hevc240-screen-20261018.png`；SSD `IMG_0021.mov`、`IMG_0022.mov` 保留
- 1080p120 K/IMU 原始计数：`/tmp/gyrocine-img0021-camera-frames.jsonl`、`/tmp/gyrocine-img0021-imu-raw.jsonl`
- 剩余时间修正编译：`/tmp/gyrocine-stability-build-20261018.log`、`/tmp/gyrocine-stability-signed-build-20261018.log`，均 `BUILD SUCCEEDED`；装机与配置恢复截图 `/tmp/gyrocine-postinstall-restored-20261018.png`、`/tmp/gyrocine-final-restored-20261018.png`
- SSD 规格表下限修正增量构建：`/tmp/gyrocine-stability-signed-build2-20261018.log`，`BUILD SUCCEEDED`；覆盖安装及恢复截图 `/tmp/gyrocine-latest-build-restored-20261018.png`
- 无线设置 UITest 构建成功、runner 连接失败：`/tmp/gyrocine-settings-bft-20261018.log`、`/tmp/gyrocine-wifi-settings-20261018.log`、`/tmp/gyrocine-wifi-settings-20261018.xcresult`
- 最新无线设置 UITest：`/tmp/gyrocine-settings-retry-bft-20261018.log`（构建通过）、`/tmp/gyrocine-wifi-settings-retry-20261018.log`（Xcode 无目标设备，方法未执行）
- 模拟器设置 UI：`/tmp/gyrocine-settings-sim-20261018.xcresult`；Swift 单测：`/tmp/gyrocine-unit-sim-20261018.xcresult`
- Gyroflow 抽检：`/tmp/gyrocine-gf-qa-20261018.mov`（Mac 复制件）、`/tmp/gyrocine-gf-qa-20261018_stabilized.mp4`（903 帧，完整解码）；手机原片保留
- 续测电量与配置截图：`/tmp/gyrocine-resume-battery-20261018.png`，手机仍连 Wi-Fi 且 SSD/IMU 状态正常，电池仍红；高带宽长录等待充电
- SSD 素材页及恢复截图：`/tmp/gyrocine-ssd-media-20261018.png`、`/tmp/gyrocine-after-media-restored-20261018.png`；测试片未删除
- 英文存储值显示修正：`/tmp/gyrocine-settings-preview-20261018.png`（修前）、`/tmp/gyrocine-settings-storage-english-fixed-20261018.png`（修后）、`/tmp/gyrocine-after-settings-fix-ready-20261018.png`（覆盖安装后原配置恢复）；构建日志 `/tmp/gyrocine-settings-storage-localization-build-20261018.log`
- 英文存储值自动回归：`/tmp/gyrocine-english-storage-regression-20261018.log`、`/tmp/gyrocine-english-storage-regression-20261018.xcresult`，1 项通过

## 后续顺序

### 待补的发版门槛

2026-10-18 09:19 非 SSD 续测：iPhone 18 Pro Max 再次通过 `localNetwork` 连接，电池已显示绿色充电。重启 Mac 当前用户 `CoreDeviceService` 后无线 XCTest Runner 仍在 `dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface` 握手阶段退出 code 74；测试方法未执行，日志 `/tmp/gyrocine-nonssd-driver-check-20261018.log`。不再将此问题归咎于 App 功能。

使用现有 Debug 自动录制入口，经 Wi-Fi 在**内部文件**录制 H.265 3840×2160／60fps：`UITEST_IMG_2026-10-18-09-22-09.mov`，20.142s、1208/1208 帧完整解码、平均 59.975fps、最大帧间隔 18.33ms、估计缺帧 0；AAC 音频一轨、内嵌 IMU。原片在 App `Documents/Media`，结果 `/tmp/gyrocine-internal-hevc4k60-20261018.json`。随后已启动同配置 5 分钟内部长录，运行中截图 `/tmp/gyrocine-internal-5min-running-20261018.png` 可见 `LOCAL ✓`、`IMU ✓`、录制时间 00:00:20、约 57.8GB 空余；自动停止与文件级结果仍待核验。

**内部 H.265 4K60 五分钟 PASS：** `UITEST_IMG_2026-10-18-09-23-12.mov`，300.108s、18007/18007 帧全解码、平均 60.002fps、最大间隔 18.33ms、估计缺帧 0，音频一轨、内嵌 IMU，640.5MB；自动停录后回到 Ready。结果 `/tmp/gyrocine-internal-hevc4k60-5min-20261018.json`。录制时屏幕预测剩余时间由约 54 分钟变成约 112 分钟，估算稳定性需单独复查。

**专用视频存储 RAW 4224×2240／30fps 一分钟 PASS：** `UITEST_IMG_writer_4DC0F513-DA39-45D6-B19F-98FAB943AA14.mov`，60.013s、1800/1800 帧全解码、平均 29.993fps、最大间隔 35ms、估计缺帧 0，音频一轨、内嵌 IMU，2.844GB。结果 `/tmp/gyrocine-pvs-raw60-result-20261018.json`。其后尝试五分钟时误带 `--ssd-matrix`，该参数把 RAW Writer 在约 8 秒自动停下；`UITEST_IMG_writer_64141B09-CD12-46E6-923D-713BE14ED710.mov` 为 8.035s 完整短片，241/241 帧、0 估计缺帧、有音频/IMU，证据 `/tmp/gyrocine-pvs-raw-unintended-short-20261018.json`。这段**不计五分钟长录**；已移除冲突参数重开五分钟测试，结果待核验。

**专用视频存储 RAW 五分钟 PASS：** 修正测试启动参数后的 `UITEST_IMG_writer_7005690B-DAE6-459C-9C87-72BAEEB572B3.mov`，300.030s、8999/8999 帧全解码、平均 29.994fps、最大间隔 35ms、估计缺帧 0；音频一轨、内嵌 IMU，15.543GB。自动停录并完成封装后回到 Ready；结果 `/tmp/gyrocine-pvs-raw5min-result-20261018.json`。专用存储容量运行中从约 149.6GB 下降到 134.5GB，截图 `/tmp/gyrocine-pvs-raw5min-mid-20261018.png`、`/tmp/gyrocine-pvs-raw5min-near-end-20261018.png`。原片保留供复查。

**专用存储同进程连续再录 PASS：** `--writer-repeat` 自动连录三段约 5 秒 RAW，产生 `UITEST_IMG_writer_AABB0650-21D5-4DA2-A323-D9C8476C201E.mov`、`UITEST_IMG_writer_7C86A53D-EF77-444A-B072-2916CA47DAA0.mov`、`UITEST_IMG_writer_11B0BD1D-7C80-4CD2-962E-6F7AD0E8DCD0.mov`。三段分别 152/152、151/151、150/150 帧全解码，均 0 估计缺帧、有音频与内嵌 IMU。独立结果 `/tmp/gyrocine-pvs-repeat-first-20261018.json`、`/tmp/gyrocine-pvs-repeat-second-20261018.json`、`/tmp/gyrocine-pvs-repeat-last-20261018.json`。

**手动曝光适配真机 PASS（0.5×→1×、30→120fps）：** 为真实跨物理镜头复测，仅在 DEBUG 自动测试入口增加 `--exposure-start-ultrawide`，编译并覆盖安装，保留 App 数据。1/50 秒、ISO 400 手动意图从超广角 `built-in_video:5` 切到主摄 `:0` 后保持；切到 120fps 后曝光被钳为 1/120 秒、ISO 稳定到约 400.04，仍为手动模式。180° 角度模式切镜后为约 1/60 秒，切 120fps 后稳定到约 1/240 秒，ISO 仍约 400.04。日志 `/tmp/gyrocine-exposure-ultra-to-wide-20261018.jsonl` 与 `/tmp/gyrocine-exposure-angle-ultra-to-wide-20261018.jsonl`。快门与 ISO 的瞬时读数需等待 AVFoundation 异步设置完成，判定取稳定后的快照。

**专用存储高规格短录及 4K120 延长录制 PASS：** RAW HQ Open Gate 4224×3024／60fps 录 15.083s，905/905 帧全解码、最大间隔 16.67ms、估计缺帧 0、音频和内嵌 IMU 齐全，3.540GB（`/tmp/gyrocine-pvs-hqog60-result-20261018.json`）。RAW 4224×2240／120fps 的 10.005s 短录为 1200/1200 帧（`/tmp/gyrocine-pvs-raw4k120-result-20261018.json`）；随后 60.053s 延长录制为 7203/7203 帧全解码，平均 119.943fps、最大间隔 10ms、估计缺帧 0，音频和内嵌 IMU 齐全，17.834GB（`/tmp/gyrocine-pvs-raw4k120-60s-result-20261018.json`）。三段原片仍在 App `Documents/Media`。本机专用存储 120fps 通过，不能外推到之前测速不足的外接 SSD。

**内部 H.265 高帧率：** 1920×1080／120fps 录 20.042s，2404/2404 帧全解码、平均 119.950fps、最大间隔 8.75ms、估计缺帧 0，音频及内嵌 IMU 齐全（`/tmp/gyrocine-internal-hevc1080p120-20261018.json`）。1920×1080／240fps 录 10.070s，2416/2416 帧全解码、平均 239.921fps、最大间隔 4.58ms、估计缺帧 0，音频一轨，但无内嵌 IMU（`/tmp/gyrocine-internal-hevc1080p240-20261018.json`）；该设备此格式没有提供可用逐帧 K，Gyroflow 增稳兼容不合格，不能把视频成功当作完整通过。两段原片均在内部 `Documents/Media`。

**专用存储 RAW HQ Open Gate 60fps 一分钟 PASS：** `UITEST_IMG_writer_FCC0B7AE-054F-4889-992B-46DE6F936332.mov`，4224×3024，60.082s、3605/3605 帧全解码，平均 60.002fps、最大间隔 18.33ms、估计缺帧 0，音频一轨、内嵌 IMU，15.896GB。结果 `/tmp/gyrocine-pvs-hqog60-60s-result-20261018.json`，录制中截图 `/tmp/gyrocine-pvs-hqog60-60s-running-20261018.png`；保存后返回 Ready 截图 `/tmp/gyrocine-pvs-hqog60-60s-finalizing-20261018.png`。专用存储剩余约 122.6GB，未安排该高规格五分钟录制。

**非 SSD 真机 UI：** 用户接回 USB 后，首轮 XCTest 仍在 `dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface` 退出 code 74。按 `docs/XCTEST_CONNECTION_2026-10-17.md` 重启当前用户 CoreDeviceService、确认 wired 新隧道后，`testEnglishDeviceScreens` 通过（设置与 LUT 英文截图，`/tmp/gyrocine-usb-fresh-tunnel-20261018.xcresult`）。`testQuickCaptureAndMediaCards` 首次因测试脚本只认中文删除按钮失败；修为中英文兼容后重跑通过（拍摄配置入口、Media 网格、长按多选、删除确认取消、分享入口；没有删除/发送文件，`/tmp/gyrocine-usb-quick-media-localized-20261018.xcresult`）。`testImmediateLensSwitchAndPlayback` 已多次完成 4×→1× 选择，RAW 编码选项在单独复测中出现；最终在原生 `VideoPlayer` 的“Play”按钮查找失败。附件 `stable-playback-open` 显示 RAW 首帧，但原生播放控件未被 XCTest 识别，**播放过程仍待人工或独立播放器状态验证**；结果 `/tmp/gyrocine-usb-lens-diagnostic-20261018.xcresult`。首次编码菜单查找 5 秒超时，复测发现 XCTest 会等待 App 动画空闲约 60 秒后才继续，尚不能判定用户界面真实卡顿。`testCaptureButtonsAndInterfacePolish` 首轮未开录：测试继承上次 RAW 编码、却强制内部文件，录制条件非法；已修测试先选 H.265，需重跑。真实用户原片未删除。

上述按键测试修正后 `testCaptureButtonsAndInterfacePolish` **通过**：设置页右上关闭、震动反馈开关、无调试开关、设置页音量键不触发录制，回到取景后音量＋开录、音量－停录，Media 多选操作排布均通过；`/tmp/gyrocine-usb-capture-buttons-h265-20261018.xcresult`。`testEnglishSettingsAndSlate` 与 `testNativeMenusWithoutCamera` 均通过，验证英文场记/存储菜单及中文整行点击、文件名类型，结果 `/tmp/gyrocine-usb-settings-static-20261018.xcresult`；后者为不启动相机的设置预览模式，不能替代真实格式联动。`testBundledLUTLooks` 通过，RAW 预览中 Rec.709、Amber、Fade、Neon、Film、Portrait 依次可选、无弹窗；`/tmp/gyrocine-usb-lut-looks-20261018.xcresult`。测试脚本修复仅涉及本地化选择器及测试前 H.265 配置。

**专用存储 0.5×／4× RAW 30fps：** 物理超广角 `UITEST_IMG_writer_0329FF54-85E9-45FD-BBE3-2C9FA25DB6A0.mov`，4224×2240、15.035s、451/451 帧全解码、平均 29.997fps、最大 35ms、0 估计缺帧，有音频和 IMU（`/tmp/gyrocine-pvs-ultrawide-raw30-20261018.json`）；物理长焦 `UITEST_IMG_writer_8DB9EEB1-2305-4671-8721-716AC7C286D3.mov`，15.068s、452/452 帧全解码、平均 29.997fps、最大 35ms、0 估计缺帧，有音频和 IMU（`/tmp/gyrocine-pvs-telephoto-raw30-20261018.json`）。两段原片保留。

2026-10-18 09:00 续测：用户确认手机先前因断电关机，现已开机充电，SSD 暂未连接。`devicectl device info details` 显示通过 `localNetwork` 已连接、已解锁；无线截图及启动 GyroCine 成功。主界面显示 `SSD !`、`Free — GB`，IMU 正常，原 1×／RAW HQ／4224×2240／60fps 配置仍保存。电池图标仍为红色充电状态，暂不开始高带宽长录。截图 `/tmp/gyrocine-resume-charging-20261018.png`、`/tmp/gyrocine-resume-app-20261018.png`。GPT 周额度已重置，当前使用 0%，高于用户设定的 20% 停测线。原片及未提交改动均保留。

同次轻量真机设置 UITest 尚未运行测试方法：旧 `GyroCineUITests-Runner` 的嵌入描述文件被设备拒绝安装（`0xe8008012`）；证据 `/tmp/gyrocine-resume-settings-20261018.xcresult`。使用 Xcode 27.1 SDK 重新自动签名构建成功（`/tmp/gyrocine-resume-build-for-testing-20261018.log`），Runner 此后能安装，但在建立 XCTest 连接前退出 code 74（`/tmp/gyrocine-resume-settings-signed-20261018.xcresult`）。同一设备 `devicectl` 的局域网启动和截图均成功；此项记为测试基础设施问题，不能判定设置功能通过或失败。本次不再重复无线 Runner 重试。

- 恢复稳定的 Wi-Fi XCTest，跑“SSD 异常后不重启再录”及设置/素材真机交互闭环；专用存储 RAW 文件已核验。
- 充电后再做高带宽长录；本轮结束电池指示已红，避免电量因素干扰结果。
- 当前盘 RAW HQ Open Gate 60 已失败，需在选规格/开录前清楚提示性能限制，或换可持续写入更快的 SSD 后重测；当前证据不能把该格式判为可稳定录制。
- 当前测速结果仅在测速页面标风险，开录路径尚未引用该判定；发版前需增加开录前清楚提示并完成真机回归。
- 第二镜头 0.5× 五分钟长录已通过；Open Gate 五分钟仍待补。29.97/59.94 精确性已测出失败，RAW120 在当前 SSD 已保护停录；这些规格暂不做长录。
- Gyroflow 导入与导出抽检已通过；仍需有明显运动的素材检验自动同步与增稳质量。竖横拍真实重力方向、SSD 热拔插需要可操作手机/SSD 的现场条件；蓝牙遥控需要对应硬件。
- H.265 极低码率剩余时间估算已加入保守下限并装机截图核验；仍需复杂场景录制对照预测与实际。

上述早期阶段结论随后由下列 USB 真机与专用存储长录结果补充；以文末最新结论为准。

## 2026-10-18 USB 非 SSD 回归收尾

手机：iPhone 18 Pro Max／iOS 27.0.1，SSD 未接，USB 连接。无线 XCTest Runner 在驱动握手时报 code 74；按 `docs/XCTEST_CONNECTION_2026-10-17.md` 重启当前用户的 CoreDeviceService 一次后，USB 真机测试恢复。测试的是 Debug 构建，安装为覆盖更新，未卸载 App。

| 用例 | 结果 | 证据与范围 |
| --- | --- | --- |
| 内部 H.265 4K60 长录 | PASS | 300.108 秒，18007/18007 帧解码，实际 60.002fps，最长间隔 18.33ms，估计缺帧 0；音频与 IMU 完整。`/tmp/gyrocine-internal-hevc4k60-5min-20261018.json` |
| 内部 H.265 1080p120 | PASS | 2404/2404 帧解码，119.95fps，音频与 IMU。`/tmp/gyrocine-internal-hevc1080p120-20261018.json` |
| 内部 H.265 1080p240 | 视频/音频 PASS；Gyroflow N/A | 2416/2416 帧、239.92fps；该设备/格式无逐帧 K，因此无可匹配的内嵌 IMU。`/tmp/gyrocine-internal-hevc1080p240-20261018.json` |
| 专用存储 RAW 4224×2240／30 | PASS | 五分钟 8999/8999 帧，29.994fps，最长 35ms，估计缺帧 0，有音频和 IMU；同进程连续三次短录也通过。`/tmp/gyrocine-pvs-raw5min-result-20261018.json` |
| 专用存储 RAW 4224×2240／120 | PASS（1 分钟） | 7203/7203 帧，119.943fps，最长 10ms，估计缺帧 0，有音频和 IMU。`/tmp/gyrocine-pvs-raw4k120-60s-result-20261018.json` |
| 专用存储 RAW HQ Open Gate／60 | PASS（1 分钟） | 3605/3605 帧，60.002fps，最长 18.33ms，估计缺帧 0，有音频和 IMU。`/tmp/gyrocine-pvs-hqog60-60s-result-20261018.json` |
| 专用存储 0.5×、4× RAW30 | PASS（各 15 秒） | 均全帧解码、无估计缺帧、有音频和 IMU。`/tmp/gyrocine-pvs-ultrawide-raw30-20261018.json`、`/tmp/gyrocine-pvs-telephoto-raw30-20261018.json` |
| 容量不足前置拒录 | PASS（注入） | `--storage-low-space-smoke` 注入低剩余空间，开录前显示明确提示，日志无 `movie_recording_started`。`/tmp/gyrocine-internal-lowspace-events-20261018.jsonl` |
| 录制中容量下降保护 | PASS（注入） | 内部 H.265 4K60 开录后 `--storage-stop-smoke` 于约 4 秒模拟可用容量低于 5 GB 保留线，日志出现 `storage_safety_stop`；已生成 MOV 为 3.583 秒、215/215 帧全解码、60.0fps、最大间隔 16.667ms、估计缺帧 0，有 AAC、RTMD 359 包和 K 元数据轨。`/tmp/gyrocine-inrecord-lowspace-events-20261018.jsonl`、`/tmp/gyrocine-inrecord-lowspace-20261018.mov`。这验证停录状态机，未模拟真实磁盘写满或存储设备突然断开。 |
| 内部文件删除回收 | PASS | USB UITest 创建 30 秒 H.265 并只删除该测试文件，素材消失。`/tmp/gyrocine-usb-internal-reclaim-20261018.xcresult` |
| 专用存储删除回收 | PASS | USB UITest 创建 30 秒 RAW，删除指定 `UITEST_` 文件后，专用容量显示 135.7→135.9 GB；日志 `AVProVideoStorage` 增加 198,070,272 字节。`/tmp/gyrocine-usb-pvs-reclaim-30s-20261018.xcresult`、`/tmp/gyrocine-pvs-reclaim-30s-events-20261018.jsonl` |
| 后台中断后重开 | PASS | USB UITest 录内部 H.265，进入后台、终止并重开 App，素材页出现 `IMU`，无错误弹窗。复制该次 `UITEST_IMG_2026-10-18-10-58-59.mov` 后核验：5.2 秒、HEVC 3840×2160／60fps、312 视频包（其中前导 6 包标为 discard）、其余 306 帧最长间隔 16.667ms、估计缺帧 0；AAC 音频、Sony RTMD 520 包与 K 元数据轨齐全，全帧 FFmpeg 解码无错误。`/tmp/gyrocine-usb-bg-finalize-20261018.xcresult`、`/tmp/gyrocine-bg-finalize-20261018.mov`。 |
| 设置、素材、语言、LUT、音量键、RAW 白平衡 | PASS（UI） | `testEnglishDeviceScreens`、`testQuickCaptureAndMediaCards`、`testCaptureButtonsAndInterfacePolish`、`testEnglishSettingsAndSlate`、`testNativeMenusWithoutCamera`、`testBundledLUTLooks`、`testRAWWhiteBalanceAlwaysLocked` 均通过；分别见 `/tmp/gyrocine-usb-*.xcresult`。LUT 测试只验证 UI 选择，无逐帧 GPU 性能结论。 |
| 手动曝光切镜头与 FPS 往返 | PASS（UI 与实际设备读数） | 0.5×→1× 后快门约 1/501、ISO 250、WB 6499K；改为 60fps 再回 30fps 后快门约 1/500、ISO 250，测试断言 WB 误差在 3% 内。`/tmp/gyrocine-usb-manual-preserve-fixed-20261018.xcresult`。首次尝试仅因旧“完成”文字选择器失败，改为 `captureSettingsClose` 后通过；XCTest 的菜单动画空闲等待使此用例耗时 292 秒。 |
| 九宫格与水平线开关 | PASS（UI） | USB UITest 打开两项并截图，随后恢复测试前开关值；`/tmp/gyrocine-usb-guides-fixed-20261018.xcresult`。未实际转动手机验证重力水平线的物理方向。首次尝试因设置列表尚未滚动到开关处而未找到元素，修正脚本后通过。 |

**专用容量修正：** 旧逻辑只要 `remainingCapacity < initialCapacity`，启动、前台和删除后就反复尝试 `replenishCapacity`，现存录像也会让条件长期成立；系统空间不够时返回 `AVFoundationErrorDomain -11800`，可能延迟相机 Ready。本轮改为启动/前台各尝试一次，删除后仅在无容量增益且有错误时有限重试；有增益即停止。删除一段已核验的 15.896 GB `UITEST_` 片段后，普通空间短暂释放，专用空间恢复约 15.12 GB；随后不足以恢复到初始值的重试曾报错。修正已编译，30 秒 UITest 回归通过。改动位于 `Sources/CameraManager.swift`，编译日志 `/tmp/gyrocine-pvs-replenish-fix-build-20261018.log`。仅清理明确识别的本轮测试文件；其他原片保留。

**剩余项：** SSD 规格矩阵、盘拔插和测速回归等待 SSD；运动场景下 Gyroflow 增稳质量、横竖方向、实际蓝牙遥控器、长录中途空间下降及 Release 候选构建尚未完成。Media 原生播放控件未暴露给 XCTest：`testImmediateLensSwitchAndPlayback` 成功切镜头并显示 RAW 帧，但脚本无法点到 `Play`，不能据此判定播放过程无闪烁。部分真机菜单触发 XCTest 约 60 秒动画空闲等待，静态设置测试已通过，完整动态规格联动尚未闭环。上述 `PASS` 仅适用列出的配置和 Debug 构建，不代表完整发版验收。

**收尾状态：** 最终 Debug 增量构建 `/tmp/gyrocine-final-restore3-build-20261018.log` 成功并覆盖安装。真机测试后已恢复为测试前的 1×／ProRes RAW HQ／4224×2240／60fps／外部 SSD，以及角度显示、A-Max、自动 ISO、EV 0、AF-C、LUT Off；不带测试参数重开截图 `/tmp/gyrocine-usb-final-restored3-20261018.png`。当前手机没有接 SSD，所以 `SSD !` 与剩余空间 `—` 为预期状态。恢复事件 `/tmp/gyrocine-final-restore2-events-20261018.jsonl` 核对编码/格式/FPS、自动曝光与自动白平衡成功；最后一次角度显示又由普通启动截图确认。测试生成的原片保留在 `Media`；没有删除用户既有素材。

**后续配置限制：** 因 1080p240 在当前设备上缺少可用于 Gyroflow 的 K/IMU，现已移除所有 240fps 菜单项，配置恢复时把旧 240fps 请求降到最高 120fps，录制配置入口也拒绝超过 120fps。上文 240fps 测试保留为历史证据，不表示新构建仍可选择该规格。Debug 真机 `build-for-testing` 成功；单元测试验证旧配置回退，iPhone 18 Pro Max UI 测试验证 H.265 1080p 菜单不再显示 240.0fps、仍显示 120.0fps，见 `/tmp/gyrocine-disable-240-device-20261018.xcresult`。新版已安装，原有拍摄配置已恢复；启动截图 `/tmp/gyrocine-disable-240-restored-20261018.png`。
