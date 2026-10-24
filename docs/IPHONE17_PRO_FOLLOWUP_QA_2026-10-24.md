# iPhone 17 Pro 补充回归 · 2026-10-24

## 环境与边界
- 代码：master / 034aa01；Debug 真机安装，Xcode 27.1。
- 手机：iPhone 17 Pro，iOS 26.0.1；USB，未连接 SSD。
- 初始补测无产品修改；随后按用户要求修复 Apple Log 2，并将 ProRes 422 普通内录改为 DataOutput + AssetWriter，见末尾。
- 以下是录制文件/自动化的验证结果，不代表 Gyroflow 导出或全部机型验收。

## 录制结果
| 配置 | 时长 / 帧数 | 最大帧间隔 | 结果 |
|---|---:|---:|---|
| ProRes Proxy / 4K30 / Apple Log | 8.067 秒 / 242 | 33.333 ms | 通过 |
| ProRes HQ / 4K30 / Apple Log | 8.133 秒 / 244 | 33.333 ms | 通过 |
| ProRes 422 / 4K30 / Apple Log + LUT 烧录 | 8.034 秒 / 241 | 33.367 ms | 通过 |
| ProRes LT / 4K30 / Apple Log / 免费时限 | 120.035 秒 / 3601 | 35 ms | 通过 |
| H.265 / 4K60 | 20.108 秒 / 1206 | 18.333 ms | 通过 |

- 五段均在手机上完成逐帧解码，帧数匹配，有音轨及遥测，无检测到的缺帧。
- 免费时限用测试入口强制免费状态：120 秒触发停止，封装约 1.266 秒。此项不等同真实沙盒购买测试。
- LUT 使用纯红测试 cube：Mac 解码输出 RGB=254,0,0，确认烧录进入画面；输出为 10-bit 4:2:2 / Rec.709。
- LUT GPU 平均 6.35 ms、最高 37.04 ms，队列峰值 2 帧，停止到 writer 完成约 0.008 秒。
- Proxy/HQ/LUT 的逐帧 K 分别 242/244/241，来自 CameraIntrinsicMatrix，无插值及回退。
- H.265 与 LUT 文件独立 K 校验通过，最大对齐差分别 1.234 ms / 0.185 ms。
- Apple Log 采集配置已确认；MOV 显示 BT.2020 primaries。未在达芬奇复核其自动色彩识别。

## UI 自动化
- 对焦：长按锁定、点击恢复连续对焦，通过。
- 素材：卡片、多选、删除确认取消、分享面板，通过；未实际分享给他人。
- 主界面拍摄配置入口，通过。
- LUT 中英文开关、重启持久化、主界面列表同步：通过（110.94 秒）。前两轮自动点击未命中；改为滑块左上部点击后通过，产品代码未改。
- 全量编码/色彩菜单组合测试：原生菜单动画等待超时，未完成，不计通过。

## 发现的问题与未覆盖项目
1. 原生 ProRes LT 4K60 内录：设置可选，但开始录制时系统明确拒绝，要求外部存储。应在能力/存储组合筛选或提示上改进。未修改产品逻辑；重新启动后后续录制成功，同进程恢复尚未验收。
2. RAW 与原生 ProRes 4K60 的实际录像：缺少 SSD。本机 iOS 26 无应用所需的 iOS 27 专用存储路径，不能拿内录替代。
3. ProRes/H.265 切回 RAW 的文件验证、SSD 拔插与测速：待 SSD。
4. RAW 时间轴、高帧率 RAW、Gyroflow 末尾播放/导出及光学同步：未在本轮验证。
5. 5 分钟以上长录制、热稳定性、真实购买/兑换/恢复：本轮未覆盖。

## 证据
- 精简文件级结果：[qa-evidence/2026-10-24-iphone17pro](qa-evidence/2026-10-24-iphone17pro)。
- XCTest：/tmp/gyrocine17-ui-20261024.xcresult。
- LUT 最终重试：/tmp/gyrocine17-lut-final-20261024.xcresult。
- MOV 与原始采集诊断保留在 /tmp/gyrocine17-final-logs 等本机目录，未将录像提交到 Git。

## 用户反馈后的再次复现（08:39）
- 用户实际失败配置：ProRes 422 LT / 4K60 / Apple Log / 内部文件。
- 自动运行同配置再次失败：MovieFileOutput 明确报 external storage required。
- 仅改为 30fps：5.133 秒，154 帧，全部解码，有音轨/遥测，无缺帧。
- 因此 4K30 的成功结论成立；4K60 内录不可用，不能概括为所有 ProRes 422 配置可用。

## Apple Log 2 修复与验证（08:43）
- 修正 CameraModels 中 Apple Log 2 可用版本：iOS 27 改为 SDK 声明的 iOS 26；仍依据当前格式 supportedColorSpaces 筛选。
- Debug 编译通过并覆盖安装。iPhone 17 Pro / iOS 26.0.1，ProRes 422 LT / 4K30 / Apple Log 2：8.1 秒、243 帧全部解码、无缺帧、有音轨及遥测。activeColorSpace=4，确认实际生效。
- 未改变 MovieFileOutput / DataOutput+AssetWriter 路由；4K60 内录限制仍未解决。

## ProRes 422 内录改用 DataOutput + AssetWriter（08:51）
以上 MovieFileOutput 4K60 失败为修改前结果。修改后普通内部文件的 ProRes 422 全系列使用现有样本写入器；SSD/专用存储及 RAW 路径保留。闲置 MovieFileOutput 只配置当前支持的编码，不再强制将 Log 2 配成 H.265。Log/HDR 数据路径要求可用的 10-bit 输入；无 LUT 时直接 append 采集样本，保留原始 PTS 和附件，不做 LUT 渲染。

| 配置（均为 4K60 内录） | 时长 | 帧数 | 解码/音频/遥测 |
|---|---:|---:|---|
| ProRes 422 LT / Apple Log 2 | 15.016 秒 | 901 | 通过 |
| ProRes 422 HQ / Apple Log 2 | 30.066 秒 | 1804 | 通过 |
| ProRes 422 / Rec.709 | 8.016 秒 | 481 | 通过 |
| ProRes 422 Proxy / HDR | 8.033 秒 | 482 | 通过 |
| H.265 回归 | 8.100 秒 | 486 | 通过 |

- 五段均逐帧解码完成，estimatedMissingFrames=0。
- LT Mac 文件验证：apcs / yuv422p10le；AAC 48kHz 双声道；901 帧 K 校验通过，最大对齐差 0.318 ms。
- LT writer 峰值队列 1 帧，停止到写入完成 8.76 ms；无 LUT 的 GPU 渲染耗时为 0。
- Debug 编译、安装通过，git diff --check 通过。
- 本轮属于短录回归（最长 30 秒）；未验证新路径的分钟级热稳定性、SSD、专用存储及其他手机。
- 原始结果为证据目录中的 writer-*.json；测试素材保留，未提交录像。
