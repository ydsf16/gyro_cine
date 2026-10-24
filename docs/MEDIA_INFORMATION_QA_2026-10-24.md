# 录制元信息与素材信息页 · 2026-10-24

## 功能
- 素材播放页底部增加 ⓘ，展示实际文件的编码、尺寸（含方向）、帧率、时长、大小、拍摄日期、色彩空间、音频和 IMU 轨道状态。
- 展示录制开始时的快门、ISO、光圈、白平衡、色调，以及机型、物理镜头类型、变焦倍率和场记。
- 场记增加备注；旧场记 JSON 不含 notes 时仍可读取。
- 中英文随应用语言，完成按钮在右上角。

## 文件契约
- MovieFileOutput、普通 ProRes / LUT 实时 writer、RAW writer 三条入口统一加入元信息。
- 标准 QuickTime 标签：make、model、software、creationdate（ISO 8601，含时区）。
- 拍摄参数：`com.tinygrape.gyrocine.capture` UTF-8 JSON，schema=1，scope=recordingStart。
- RAW 合并系统推荐元信息，保留系统机型名称、白平衡/色彩校准矩阵等字段。
- 场记和备注直接嵌入 MOV，不依赖 App 日志或素材数据库；复制原文件后仍保留。
- 自动曝光/白平衡可能变化，快照不表示全程恒定；原有逐帧曝光、IMU、K 数据照常写入。
- 信息页只读取文件头，后台解析，不解码视频。旧文件缺失字段显示 —，已有 RAW 标准 ISO/快门/白平衡字段可回读。
- 未增加代理视频生成、GPS 或专业时间码。

## 验证
- Debug 真机目标和 Release 构建均通过。
- 模拟器单元测试 5 项通过：原有场记命名/递增、旧 JSON 兼容、元信息合并、实际 MOV 写入并读取。
- MOV 回读测试覆盖竖屏尺寸、编码、ISO、快门、白平衡、色调、中文备注、场景、日期和无 IMU 的正确状态。
- 中英文 UI 自动测试通过：打开素材 → 信息页、读取拍摄参数、关闭信息页并返回素材。使用模拟器和 AVFoundation 生成的测试 MOV。
- 新元信息已在 iPhone 17 Pro 实录验证：H.265、H.265 HQ、ProRes HQ / 422 / LT / Proxy 共 6 组全部通过；标准标签、快门/ISO/光圈/白平衡/色调、镜头、场记及中文备注均回读成功。原 748 组基线不含这些新增标签。

## 复测与证据
- 单元测试：`xcodebuild -project gyro_cine.xcodeproj -scheme GyroCine -destination 'platform=iOS Simulator,id=SIMULATOR_ID' -only-testing:GyroCineTests/RecordingSlateTests test`。
- UI 用例：`GyroCineUITests/IMURecordingUITests/testMediaInformationBothLanguages`。先用 `swift tools/create_media_information_fixture.swift input.mov output.mov` 生成测试文件，再放到模拟器 App 的 `Documents/Media/UITEST_METADATA.mov`。input 可为任意短 H.264 MOV，生成文件不能用于相机采集验收。
- UI 命令建议增加 `-parallel-testing-enabled NO -collect-test-diagnostics never`；本次一次结果收集挂起，用例已通过后终止收集，随后独立重跑完整成功。
- 最终 UI 结果：`/tmp/GyroCineMetadataUIFinal.xcresult`，退出码 0，TEST SUCCEEDED。
- 中英文截图：`docs/qa-evidence/2026-10-24-media-information/`。

## 真机截图复查
- 首次真机 UI 操作测试通过，但截图发现 IMU 状态误报。AVFoundation 的公开轨道描述没有暴露 Sony rtmd；MOV 本身包含正确遥测轨道。
- 已改用与素材角标一致的 MOVTelemetryMuxer.hasTelemetry 文件头检测，UI 测试增加“已嵌入 / Embedded”断言，重新验证。
- 新 MOV 复制出 App 后用 ffprobe 确认标准标签仍在，H.265 / 1920×1080 / AAC 48kHz 双声道及自定义拍摄快照保留。
- RAW 的元信息入口已接入，并有系统校准字段合并单元测试；本轮无 SSD，未声称新 RAW 实录通过。

## 最终结果
- 真机 XCTest：1/1 通过，包含 IMU“已嵌入”断言、打开信息页、滚动查看、关闭并返回素材。
- 最终结果包：`/tmp/GyroCineDeviceMetadataVerified.xcresult`；真机截图 `qa-evidence/2026-10-24-media-information/device-metadata-*.png` 已人工检查。
- 模拟器中英文 UI、5 个单元测试、6 种编码真实文件检查分别通过，不混用验收范围。
- 修复版已安装到 iPhone 17 Pro，并以普通模式启动，未继续自动录制；保留 6 段短元数据样本及 UI 测试副本供查看。
- 本轮未提交 Git。

## 后续 SSD RAW 验证

- 2026-10-24 后续接入 SSD，RAW / RAW HQ 实录、文件元信息和中英文真机页面显示已验证，见 [RAW SSD 信息页报告](RAW_SSD_INFORMATION_QA_2026-10-24.md)。
- 新增 GPS 功能另见 [定位报告](LOCATION_RECORDING_QA_2026-10-24.md)；上方“未增加 GPS”描述仅指最初信息页实现。
