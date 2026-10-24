# 视频定位 · 2026-10-24

## 行为
- 设置 → 录制 → 记录位置，默认关闭，开关持久化，中英文随 App 语言。
- 开启时请求“使用 App 期间”定位；拒绝时显示系统设置入口。关闭或进入后台停止定位并清空缓存。
- 录制开始时把最近 60 秒内的有效坐标写入标准 QuickTime `com.apple.quicktime.location.ISO6709` 字段。支持系统近似定位；不写无效、过期或未授权的位置。
- 定位未就绪时不写坐标，不等待 GPS、不阻塞录制、不事后修改坐标。
- H.265 MovieFileOutput、普通 ProRes / LUT writer、RAW writer 统一使用该快照。原有 IMU、逐帧时间和图像链路未改变。
- 素材信息页显示文件中的坐标；位置随原视频分享。关闭只影响后续录像。
- 双语权限说明、仓库隐私政策已更新；未发布网站。

## 已执行测试
- 单元测试 6/6：坐标符号和补零、关闭/拒绝/无位置、过期/未来时间、无效精度、近似定位以及真实 MOV 写入回读。
- 真机 iPhone 17 Pro / iOS 26.0.1：中英文设置开关 UI 通过；真实定位就绪后，录制开启/关闭各一段的 UI 测试通过。
- ProRes Proxy 两段原始 MOV 复制到 Mac，用 ffprobe 确认开启有标准坐标、关闭无坐标，音频和 rtmd 轨道保留。
- H.265 1080p23.976 / 30 开启定位各一段、1080p23.976 关闭一段：3/3 通过视频解码、帧间隔、IMU/K 和文件检查；位置存在性符合开关状态。
- Release 构建通过；新版已安装，测试结束恢复普通启动，定位开关保持关闭。
- RAW 未实录：当前无 SSD；仅完成共用元信息入口接入。

## 证据
- 单元测试：`/tmp/GyroCineLocationUnitFixed.xcresult`。
- 中英文 UI：`/tmp/GyroCineLocationDeviceUI2.xcresult`。
- 真机开关录制：`/tmp/GyroCineLocationRecording.xcresult`。
- 仓库精简证据：`qa-evidence/2026-10-24-location/`，不包含真实坐标。
- 初次单元测试发现 Foundation 带 locale 格式化时未正确补零，已改为显式拼接符号和零并复测通过。
- 初次 UI 测试点标签未切换成功，改为明确点击开关滑块后中英文通过。
