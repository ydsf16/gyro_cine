# GyroCine 快速发版实测：2026-10-19

依据：[快速发版用例库](RELEASE_TEST_CASES.md)。`PARTIAL` 和 `BLOCKED` 不算通过；本轮没有删用户素材。

| 环境 | 本轮值 |
| --- | --- |
| 代码 | `master`，`0db9e86`；仅新增本报告，未修改录制代码 |
| 候选包 | GyroCine 1.0 (20261019.5)，Release，覆盖安装后留在手机；Debug 同源码只用于自动录制入口 |
| 真机 | iPhone 18 Pro Max / iOS 27.0.1，UDID `00008160-000A6CEA3E40000A` |
| 连接与存储 | 录制阶段为 `localNetwork` + SSD `PortableSSD`；补测阶段通过 USB，SSD 已取下；手机专用视频存储可用 |
| 自动化 | `devicectl` 无线完成录制与文件检查；无线 XCTest 三次在 driver bootstrap 报 code 74。改用 USB 后 XCTest 能运行真机 UI 测试 |

## 结果

| 用例 | 状态 | 证据与限制 |
| --- | --- | --- |
| Q1 启动与配置 | PASS（启动/持久化） | Release 无线覆盖安装、启动并显示相机预览、PVS ✓、IMU ✓；测试后重装 Release，原有 1×／H.265／3840×2160／60fps／PVS 设置恢复，见 `/tmp/gyrocine-quick-final-release-restored-20261019.png`。设置页点击交互另见 Q4。 |
| Q2 H.265 基础片 | PASS（文件） | 内部文件 4K60：20.05 秒／1203 帧、60.000fps、最大间隔 16.67ms、估计缺帧 0、AAC 1 轨、IMU 在 MOV 中；5.13 秒再录片 308 帧、缺帧 0。两片拷到 Mac 后 `ffmpeg` 全帧解码退出码 0。证据 `/tmp/gyrocine-quick-hevc20-result.json`、`/tmp/gyrocine-quick-hevc2-result.json` 与相应 MOV。 |
| Q3 RAW 基础片 | PASS（SSD/专用存储文件） | SSD RAW `aprn` 4224×2240/30：15.00 秒、450/450 帧在手机用 AVAssetReader 完整解码、缺帧 0、AAC 1 轨、IMU 在 MOV 中；同片 `camera_frames.jsonl` 450 条有效 K，原始 IMU 从首帧前约 166ms 到末帧后约 213ms。SSD RAW HQ `aprh` 5.03 秒、151/151 帧完整解码、缺帧 0、AAC/IMU 均在。专用存储 RAW 5.07 秒、152/152 帧完整解码、AAC/IMU 均在。证据 `/tmp/gyrocine-quick-raw15ssd-final-result.json`、`/tmp/IMG_0010.camera_frames.jsonl`、`/tmp/IMG_0010.imu_raw.jsonl`、`/tmp/gyrocine-quick-rawhqssd-result.json`、`/tmp/gyrocine-quick-rawpvs-result.json`。SSD 原片保留在 `DCIM/100APPLE/IMG_0007` 至 `IMG_0010.mov`。 |
| Q4 镜头/参数 | PARTIAL | USB XCTest 完成三轮 4×↔1×、RAW 下两轮 4×↔1×，镜头选中状态和编码菜单均正常。手动快门约 1/250、ISO 2498、白平衡 7338K，经 0.5×→1× 和 30↔60fps 后保持，`testControlsManualSurvivesLensAndFPS` 通过。近远对焦效果仍需移动实景人工观察。 |
| Q5 素材与方向 | PARTIAL | H.265 MOV 在 Gyroflow 被识别为 270°，预览竖屏；本轮真机画面、RAW writer 日志方向为 90°。USB XCTest 已验证配置卡、素材缩略图/IMU 标识、长按选择、删除确认后取消，以及分享入口，未删原片。播放器补测通过：点视频中央后进度从 0:00 走到 0:02；旧测试查找 `Play`，实际 iOS 27 控件标识为 `Play/Pause`。横竖各一片及导出方向仍未完成。 |
| Q6 后期抽查 | PARTIAL | Gyroflow 1.6.3 成功导入本轮 H.265 片，显示 3840×2160/59.975fps、AAC、IMU 和 Apple per-frame K 镜头；运动曲线可见。手机静置拍摄的天花板不能验证动态增稳，导出文件未生成，方向与末尾流畅度未验收。 |
| Q7 发布包 | PARTIAL | Release 包 plist 为 1.0 (20261019.5)、iPhone only、`UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace` 为 true；Release 重新安装并启动。Debug 的 Pro 预览页中英文 2 分钟提示、恢复购买入口、英文设置/场记和中文设置菜单 3 项 USB UI 测试通过；真实 StoreKit 交易和 Release 购买入口未验证。模拟器 Release 单测 58 项运行、0 失败、1 跳过，只作辅助证据。 |

## 工具与原始证据

- 无线 XCTest 的第三次结果：`/tmp/gyrocine-quick-after-permission-20261019.xcresult`。用户允许“仅限无线局域网”后仍为 `XCTestDriverInterface` 握手失败；之前两次见 `/tmp/gyrocine-quick-ssd-preflight-20261019.xcresult`、`/tmp/gyrocine-quick-uiconnect-retry-20261019.xcresult`。
- Release 真机构建：`/tmp/gyrocine-quick-releaseqa-build2.log`；Release 单测：`/tmp/gyrocine-quick-unit-20261019.xcresult`。
- H.265 20 秒 MOV：`/tmp/gyrocine-quick-hevc-4k60-20s.mov`；短片：`/tmp/gyrocine-quick-hevc-4k60.mov`、`/tmp/gyrocine-quick-hevc-4k60-second.mov`。SSD RAW 未经 Wi‑Fi 复制到 Mac；完整解码结论来自真机 AVAssetReader 检查结果。
- RAW 15 秒的 450 条相机内参与 3083 条原始 IMU：`/tmp/IMG_0010.camera_frames.jsonl`、`/tmp/IMG_0010.imu_raw.jsonl`。
- USB 真机 UI：`/tmp/gyrocine-quick-usb-manual-20261019.xcresult`（1/1 通过）、`/tmp/gyrocine-quick-usb-preview-20261019.xcresult`（3/3 通过）、`/tmp/gyrocine-quick-usb-media3-20261019.xcresult`（1/1 通过），镜头循环见 `/tmp/gyrocine-quick-usb-lens-20261019.xcresult`（镜头部分通过，播放器断言失败）。
- 素材播放器复测：`/tmp/gyrocine-playback-assert2-20261019.xcresult`（Release，1/1 通过）。真机设置菜单复测：`/tmp/gyrocine-menu-quiescence-20261019.xcresult`（Release，1/1 通过）与 `/tmp/gyrocine-menu-debug-20261019.xcresult`（Debug，1/1 通过）。
- 素材页第一次点击“删除”未出现确认框，是手机 AssistiveTouch 悬浮球盖住按钮中心；测试改点按钮左侧后通过，未删除文件。真机恢复到 1×／H.265／4K60／PVS／A-Max／自动 ISO 和白平衡，重新启动截图：`/tmp/gyrocine-quick-usb-final-restored-20261019.png`。
- Release 构建中的 `--pro-ui-preview` 被 `#if DEBUG` 排除，所以首次用 Release 跑该预览测试的失败属于测试配置错误；改用 Debug 后通过。实时相机页面的系统菜单在 Release 和 Debug 均使 XCTest 等待约 60 秒 `App animations complete notification not received`，然后菜单选项可操作。Debug 会话 `/tmp/gyrocine-menu-debug-focus.jsonl` 的 80 次主队列延迟采样中位数 2.64ms、最高 35.68ms，相机队列中位数 0.03ms、最高 67.50ms；这段时间没有主线程长阻塞证据。XCTest 的动画完成判定仍需单独排查，不将其记为 App 卡死。

## 发版前仍需补测

1. 在实景中验证镜头切换后的近远自动对焦；素材页播放进度已由 USB XCTest 验证。
2. 手持拍有纹理的横竖短片，Gyroflow 实际增稳导出并核对方向、首尾流畅度。当前静态画面只能证明识别与数据轨存在。
3. 用正式 Release 的 StoreKit 沙盒核验 Pro 购买/恢复。Debug 的双语页面测试不能替代真实交易。
4. 本轮 SSD RAW 只测 30fps 短片；60/120fps、高码率长录、热拔插和低空间属于详细发版测试，不能沿用此处 PASS。

本轮保留全部原片、测试日志与用户素材；未推送 Git、未上传新构建。
