# SSD ProRes RAW 素材信息页验证 · 2026-10-24

## 环境与范围

- iPhone 17 Pro，iOS 26.0.1，Wi-Fi 调试，SSD 已连接。
- ProRes RAW / RAW HQ，4224×2240、30fps，后置超广角；每次约 3 秒。
- 本设备实际使用 AVCaptureMovieFileOutput 外录。此结果不覆盖专用存储 RAW writer、高帧率或长录制。
- 不增加地名查询；未删除原有 SSD 素材。

## 真实录制结果

| 文件 | 编码 | 帧数/成功解码数 | 时长 | 估计丢帧 | IMU |
|---|---|---|---|---|---|
| IMG_0034.mov | aprn | 95/95 | 3.165s | 0 | 是 |
| IMG_0035.mov | aprh | 94/94 | 3.133s | 0 | 是 |
| IMG_0036.mov | aprn | 93/93 | 3.098s | 0 | 是 |
| IMG_0037.mov | aprh | 93/93 | 3.100s | 0 | 是 |

四段完整解码，均有音频、IMU，最大帧间隔约 33.333ms。

## 信息页核对

通过 Debug 参数自动打开真实 SSD 文件的信息页，用 `devicectl device capture screenshot` 取得手机截图；读取的是正式 MovieInformationLoader / MovieInformationView，没有模拟数据。

- RAW / RAW HQ 正确区分，竖屏显示 2240×4224，30.000fps。
- 时长、大小、日期与文件一致；色彩显示 RAW；音频为 lpcm、48kHz、双声道。
- IMU 显示“已嵌入 / Embedded”。
- 快门、光圈、ISO、白平衡、色调与 MOV capture 快照一致。
- 机型显示 iPhone 17 Pro；镜头显示“后置 · 超广角 / Back · Ultra Wide”。
- 变焦倍率 1.00× 是该物理镜头的 videoZoomFactor，不代表主摄等效倍率。
- 机位 A、卷号 1、场景 1、镜次 838 / 839 正确；未填写的制作、导演、摄影师、备注显示 —。
- 两种编码均检查中英文首页；RAW 中文及 RAW HQ 英文额外检查参数和场记区域。共 8 张真机截图。
- 系统 RAW 校准矩阵与标准 RDD18 字段仍存在。信息页显示 recordingStart 快照，自动 ISO 与系统第一帧 RDD18 ISO 可略有不同，不代表逐帧数值恒定。

## 自动化边界

- XCTest 两次在 IDE/驱动握手阶段退出（code 74）；未执行点击用例，不计作通过。
- 改用 Debug 自动导航 + 系统真机截图完成页面显示核对。本轮没有验证实体点击“完成”的交互。
- 新增可复用 XCTest `testSSDRAWInformationBothLanguages`，通过 GYROCINE_RAW_METADATA_FILES 指定真实测试素材；没有指定时跳过。
- Debug 自动入口：`--media-ui-preview --media-info-file=IMG_0036.mov`；可加 `--media-info-section=settings` 或 `camera`。
- Debug 参数不参与 Release；Release 构建通过。录制逻辑未因本轮测试修改。

## 证据

- 本目录相邻 `qa-evidence/2026-10-24-raw-ssd-info/`：4 份录制摘要、8 张真机截图。大块系统二进制校准数据仅记录存在，避免报告膨胀。
- 原始元数据：本机 /tmp/raw-ssd-info-full.json 与 /tmp/raw-hq-ssd-info-full.json。
- XCTest 阻塞：/tmp/SSDRAWInfo.xcresult、/tmp/SSDRAWInfoRetry.xcresult。
- 构建：/tmp/raw-info-preview2-build.log、/tmp/raw-info-release.log。
- 原始样本保留在 SSD/DCIM/100APPLE/IMG_0034.mov 至 IMG_0037.mov。
- 本轮未 commit / push。
