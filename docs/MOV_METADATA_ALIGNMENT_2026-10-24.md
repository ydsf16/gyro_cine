# MOV 信息对齐 BMC（2026-10-24）

## 已实现

共用 metadata 入口覆盖 MovieFileOutput、普通/ProRes 422 的 DataOutput + Writer、RAW Writer。

- Apple ProApps 标准字段：manufacturer、clipID、cameraName、reel、scene、shot、logNote。
- 保留现有 QuickTime 厂商、型号、软件版本、拍摄日期、标题、导演、备注，以及经用户许可的定位。
- 镜头、ISO、光圈、快门秒数、白平衡色温/色调、帧率、色彩空间新增独立 GyroCine 字段，保留原有完整 capture JSON。
- 私有字段不冒用 Blackmagic 命名空间。拍摄参数是录制开始快照；RAW 文件编码仍为 RAW，另行记录所选 Apple Log / Apple Log 2 拍摄色彩空间；LUT 烧录标记 Rec.709。
- 不修改像素、音视频时间轴或 IMU。系统 RAW 校准数据与系统提供的机型信息继续保留。

## 验证

- iOS Debug build：通过。
- RecordingSlateTests：7 项通过，0 失败。
- 覆盖实际 H.264 MOV 写入/读回 ProApps 场景字段、双语备注、定位权限、二进制 RAW 校准数据合并保持不变。
- 未将上述单测视为所有格式的真机重新录制通过。

## 达芬奇 21 对照

BMC A001_10241220_C001.mov：aprn，4224×2240，24fps，2.708333 秒。
GyroCine IMG_0038.mov：aprn，4224×2240，30fps。
同一独立测试工程、Camera RAW 使用摄影机元数据：

| 文件 | 默认 RAW to Log | 拍摄白平衡 UI |
| --- | --- | --- |
| BMC 原片 | Apple Log 2 | 显示 |
| GyroCine 原片 | HLG | 未显示 |
| GyroCine 仅补 proapps.manufacturer=Apple Inc. | HLG | 显示 |
| 再将型号改为 Apple iPhone 17 Pro | HLG | 显示 |

两个副本的 mdat SHA256 与原片一致；原片未改动。副本位于 Mac 下载/GyroCine_RAW_Color_Check_20261024。
结论：厂商标记改善相机信息识别，但不足以使旧 RAW 默认 Apple Log 2。后续在采集端设置 RAW 的 `activeColorSpace`，见下方复测。

## RAW 色彩空间修复与真机复测

- iPhone 17 Pro / SSD / ProRes RAW / 4224×2240 / 30fps。设置页按当前格式能力显示 Apple Log 与 Apple Log 2；RAW 与普通编码的选择分别保存。
- IMG_0039.mov 选择 Apple Log：设备日志 `activeColorSpace=3`，录制成功，约 4.5 秒、135 帧；MOV 自定义色彩字段为 Apple Log，音频及 IMU 轨道存在。
- IMG_0040.mov 选择 Apple Log 2：设备日志 `activeColorSpace=4`，录制成功，约 4.87 秒、146 帧；MOV 自定义色彩字段为 Apple Log 2，音频及 IMU 轨道存在。
- 两段视频逐帧读取成功，最大相邻帧间隔约 33.334ms，未发现大于 50ms 的帧缺口；视频与 IMU `rtmd` 轨道帧数分别对应为 135 和 146。
- 同一达芬奇 21 工程、Camera RAW 使用“摄影机元数据”：旧 IMG_0038 默认为 HLG；新 IMG_0039 与 IMG_0040 均默认为 Apple Log 2。
- BMC 对照片 A001_10241300_C002（拍摄选 Apple Log）及 C003（拍摄选 Apple Log 2）在该版本达芬奇中也均默认为 Apple Log 2。因此达芬奇 RAW 解码菜单不与拍摄端的两种选择逐项对应，不能用菜单值判断 MOV 私有色彩字段是否保存。
- 本次验证了默认解码选项及 MOV 结构，尚未对同一场景做严格的预览与达芬奇画面亮度数值匹配。
