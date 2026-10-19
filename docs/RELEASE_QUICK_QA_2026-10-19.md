# GyroCine 快速发版实测：2026-10-19

依据：[快速发版用例库](RELEASE_TEST_CASES.md)。`PARTIAL` 和 `BLOCKED` 不算通过；本轮没有删用户素材。

| 环境 | 本轮值 |
| --- | --- |
| 代码 | `master`，`0db9e86`；仅新增本报告，未修改录制代码 |
| 候选包 | GyroCine 1.0 (20261019.5)，Release，覆盖安装后留在手机；Debug 同源码只用于自动录制入口 |
| 真机 | iPhone 18 Pro Max / iOS 27.0.1，UDID `00008160-000A6CEA3E40000A` |
| 连接与存储 | `devicectl` 为 `localNetwork`；SSD `PortableSSD` 被 App 发现；手机原有专用视频存储仍可用 |
| 自动化 | `devicectl` 无线安装、启动、截图、取日志及内部 MOV；无线 XCTest 三次均在 driver bootstrap 报 code 74，测试方法未执行 |

## 结果

| 用例 | 状态 | 证据与限制 |
| --- | --- | --- |
| Q1 启动与配置 | PASS（启动/持久化） | Release 无线覆盖安装、启动并显示相机预览、PVS ✓、IMU ✓；测试后重装 Release，原有 1×／H.265／3840×2160／60fps／PVS 设置恢复，见 `/tmp/gyrocine-quick-final-release-restored-20261019.png`。设置页点击交互另见 Q4。 |
| Q2 H.265 基础片 | PASS（文件） | 内部文件 4K60：20.05 秒／1203 帧、60.000fps、最大间隔 16.67ms、估计缺帧 0、AAC 1 轨、IMU 在 MOV 中；5.13 秒再录片 308 帧、缺帧 0。两片拷到 Mac 后 `ffmpeg` 全帧解码退出码 0。证据 `/tmp/gyrocine-quick-hevc20-result.json`、`/tmp/gyrocine-quick-hevc2-result.json` 与相应 MOV。 |
| Q3 RAW 基础片 | PASS（SSD/专用存储文件） | SSD RAW `aprn` 4224×2240/30：15.00 秒、450/450 帧在手机用 AVAssetReader 完整解码、缺帧 0、AAC 1 轨、IMU 在 MOV 中；同片 `camera_frames.jsonl` 450 条有效 K，原始 IMU 从首帧前约 166ms 到末帧后约 213ms。SSD RAW HQ `aprh` 5.03 秒、151/151 帧完整解码、缺帧 0、AAC/IMU 均在。专用存储 RAW 5.07 秒、152/152 帧完整解码、AAC/IMU 均在。证据 `/tmp/gyrocine-quick-raw15ssd-final-result.json`、`/tmp/IMG_0010.camera_frames.jsonl`、`/tmp/IMG_0010.imu_raw.jsonl`、`/tmp/gyrocine-quick-rawhqssd-result.json`、`/tmp/gyrocine-quick-rawpvs-result.json`。SSD 原片保留在 `DCIM/100APPLE/IMG_0007` 至 `IMG_0010.mov`。 |
| Q4 镜头/参数 | BLOCKED | 无线 XCTest runner 在方法开始前退出（code 74）；无法自动点击 0.5×／4×、调整手动曝光或做近远对焦。静态参数/格式单测通过，不能替代真机操作。 |
| Q5 素材与方向 | PARTIAL | H.265 MOV 在 Gyroflow 被识别为 270°，预览竖屏；本轮真机画面、RAW writer 日志方向为 90°。素材页播放、分享及横竖各一片未完成，受 XCTest 连接限制。 |
| Q6 后期抽查 | PARTIAL | Gyroflow 1.6.3 成功导入本轮 H.265 片，显示 3840×2160/59.975fps、AAC、IMU 和 Apple per-frame K 镜头；运动曲线可见。手机静置拍摄的天花板不能验证动态增稳，导出文件未生成，方向与末尾流畅度未验收。 |
| Q7 发布包 | PARTIAL | Release 包 plist 为 1.0 (20261019.5)、iPhone only、`UIFileSharingEnabled` 与 `LSSupportsOpeningDocumentsInPlace` 为 true；Release 重新安装并启动。Pro 页面、双语和购买提示的真机点击未完成。模拟器 Release 单测 58 项运行、0 失败、1 跳过，只作辅助证据。 |

## 工具与原始证据

- 无线 XCTest 的第三次结果：`/tmp/gyrocine-quick-after-permission-20261019.xcresult`。用户允许“仅限无线局域网”后仍为 `XCTestDriverInterface` 握手失败；之前两次见 `/tmp/gyrocine-quick-ssd-preflight-20261019.xcresult`、`/tmp/gyrocine-quick-uiconnect-retry-20261019.xcresult`。
- Release 真机构建：`/tmp/gyrocine-quick-releaseqa-build2.log`；Release 单测：`/tmp/gyrocine-quick-unit-20261019.xcresult`。
- H.265 20 秒 MOV：`/tmp/gyrocine-quick-hevc-4k60-20s.mov`；短片：`/tmp/gyrocine-quick-hevc-4k60.mov`、`/tmp/gyrocine-quick-hevc-4k60-second.mov`。SSD RAW 未经 Wi‑Fi 复制到 Mac；完整解码结论来自真机 AVAssetReader 检查结果。
- RAW 15 秒的 450 条相机内参与 3083 条原始 IMU：`/tmp/IMG_0010.camera_frames.jsonl`、`/tmp/IMG_0010.imu_raw.jsonl`。

## 发版前仍需补测

1. 修复/绕开无线 XCTest 驱动连接后跑 Q4、Q5、Q7 的 UI 流程，尤其镜头切换后 AF 与手动参数保持。
2. 手持拍有纹理的横竖短片，Gyroflow 实际增稳导出并核对方向、首尾流畅度。当前静态画面只能证明识别与数据轨存在。
3. 本轮 SSD RAW 只测 30fps 短片；60/120fps、高码率长录、热拔插和低空间属于详细发版测试，不能沿用此处 PASS。

本轮保留全部原片、测试日志与用户素材；未推送 Git、未上传新构建。
