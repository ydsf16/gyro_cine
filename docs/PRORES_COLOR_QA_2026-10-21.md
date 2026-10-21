# ProRes 422 与色彩空间：实现和回归

## 改动

- 保留设置、拍摄配置中的下拉选择：ProRes 422 HQ / 422 / LT / Proxy。
- 原先只查 MovieFileOutput，导致 iPhone 16 的可用 ProRes 编码器被隐藏。补充 VideoToolbox 编码器能力探测，按编码与尺寸缓存探测结果。
- MovieFileOutput 不提供 ProRes 的设备使用现有有界实时 writer：原始视频 buffer 直接交给 AVAssetWriter，保留采集 PTS、音频、方向、IMU/K 对齐；不经过 LUT 或录后转码。
- 色彩空间按同分辨率、同帧率的全部兼容格式筛选；选择后自动切换对应采集格式。Rec.709、Rec.2020 HDR（HLG）、P3 D65 不再受当前单个 Format 限制。Apple Log/Log 2 继续按设备实际支持显示。
- 未烧录 LUT 时由采集 buffer 的颜色附件传给编码器；烧录 LUT 时保持原有 GPU 转换并标记 Rec.709。ProRes 的 10-bit 输出允许 SDR 8-bit 采集输入；HDR/Log 烧录仍要求 10-bit 采集，不能静默降为 8-bit。
- 已有 H.265 和 RAW 录制路径保留；已有原生 MovieFileOutput ProRes 的设备继续走原生路径。

## 真机证据

设备：iPhone 16 YJJY，iOS 18.2.1，USB，内部文件存储。

| 配置 | 时长 / 帧数 | 结果 |
|---|---|---|
| ProRes 422 Proxy · 4K30 · Rec.709 | 4.033s / 121 | 全帧解码；10-bit 422、BT.709 |
| ProRes 422 HQ · 4K30 · HDR | 4.033s / 121 | 全帧解码；10-bit 422、BT.2020 / HLG |
| ProRes 422 · 4K30 · P3 D65 | 3.133s / 94 | 全帧解码；10-bit 422、P3-D65（smpte432） |
| ProRes 422 LT · 4K60 · Rec.709 | 4.068s / 244 | 全帧解码；最大帧间隔 16.70ms |
| ProRes 422 Proxy · 4K30 · 烧录 LUT | 3.133s / 94 | 全帧解码；Rec.709、LUT marker；停止 writer 约 28ms |
| H.265 · 4K60 · 无烧录 LUT | 4.165s / 250 | 全帧解码；原 MovieFileOutput 路径回归 |

以上每段均有 AAC 音轨和内嵌 IMU；文件时间表检查均未检测到丢帧。这里的全帧解码来自 Mac ffprobe `-count_frames`，手机结果中的 `decodeStatus: notRequested` 是手机端未额外解码，两者分别记录。

- 自动 UI 测试 `testProResAndColorMenus`：四种 ProRes 分别切换 Rec.709 / HDR / P3，再回到 H.265，120.603 秒通过、0 失败。英文 UI；选项名称与中文共用，色彩空间标题已有中英文。
- 编译通过。初次 UI 测试遇到原生 Menu 的动画/命中点问题，测试改为等待菜单展示、按真实控件坐标点击后通过。
- LUT 烧录 GPU 平均 6.98ms，最大 139.56ms，最高缓冲 5 帧，未丢帧。短录制通过不等同于长录制性能验收。

## 范围

这是功能短录制回归，不代表所有机型、全部帧率或长时间热稳定性均已验证。本轮未连接支持 Apple Log / RAW 的 Pro 机型，也未进行 SSD 或专用存储测试。

证据位于 `docs/qa-evidence/2026-10-21-prores-color/`，不包含用户视频。

## 补充：移除系统默认与 LUT 像素验证

- 色彩空间菜单移除“系统默认 / System Default”；新设置和旧默认值统一迁移到 Rec.709。RAW 内部的自动采集状态保留，但不作为用户选项。
- `testExplicitColorSpaceMenuBothLanguages` 真机通过：中文、英文均显示 Rec.709 / HDR / P3，不出现系统默认。
- `PreviewColorTransformTests` 10 项通过，包含旧默认迁移、LUT 解析、内置 LUT、Log 参考值及禁止 RAW 烧录。
- 使用专用纯红色 3D LUT 实测 ProRes Proxy 4K30：
  - Rec.709、HDR、P3，开启烧录：手机预览中心平均 RGB 约 254/1/1，视频解码平均 RGB 253/0/0，确认 GPU 预览和烧录均生效。
  - P3，仅预览、关闭烧录：手机预览仍为红色，视频 RGB 约 166/163/155，为正常场景，确认预览不会写入原片。
  - 四段均成功录制 91–92 帧，音频与 IMU 存在，无检测到的缺帧；对应文件已全帧解码。
- 测试 LUT 只用于验证处理路径，不代表对实拍场景进行了色度计校准。用户导入 LUT 仍按原定义直接使用，不自动改变其输入色彩空间。
- 补充证据：`docs/qa-evidence/2026-10-21-prores-color/lut-check/`。

- 内置 Rec.709 LUT 的 HDR 转换也已实测：渲染日志确认采用 `rec2020HLG` 转换，ProRes 输出为 BT.709，91 帧全部解码、IMU 正常；GPU 平均 6.06ms，峰值 10.19ms，最高缓冲 1 帧。
