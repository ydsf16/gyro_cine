# 相机控制与界面验收 — 2026-10-11

## 09:57 录制位置与机型能力显示

- 设置增加“录制位置：文件 / SSD”，默认“文件”。iOS 把 App 的 Documents 目录显示为“文件 → 我的 iPhone → RawMotionRecorder”；每段直接写入该目录下独立的 `recording_时间` 文件夹。SSD 需首次在文件选择器中选择磁盘根目录，App 在所选目录创建 `RawMotionRecorder`；书签保存后可恢复访问。拔盘或文件夹缺失时阻止录制。
- ProRes RAW / RAW HQ 在按下录制前检查 SSD 模式、目标文件夹是否存在且可写、设备是否连接、权限和空间。RAW 视频遵循 Apple 外置存储接口，拍摄期间写入 SSD 提供的安全 URL，停录后在 SSD 上归入 App 文件夹；普通编码直接写入所选文件夹。SSD 当前未连接，因此 SSD 实写、书签重启恢复与 RAW 归档 **未验收**。
- 分辨率和帧率从当前物理镜头的格式与帧率范围筛选；候选视频尺寸含 720p、1080p、1440p、UHD、DCI 4K，帧率含 24/25/30/50/60/120/240（RAW 上限候选 60）。菜单只显示设备实际报告支持的组合。编码候选结合当前 AVCaptureVideoDataOutput 报告与 RAW Bayer 格式；iPhone 17 Pro 当前 FHD/30 菜单显示 H.264、HEVC、RAW、RAW HQ，隐藏不支持的 ProRes 422/422 HQ。
- 真机无 SSD 时选择 RAW，设置页明确提示 SSD 要求；在“文件”位置按录制，显示“请将录制位置改为 SSD”，没有生成片段。证据 `/Users/grape/project/ios_device_control/evidence/storage_raw_hint.png`、`storage_raw_denied.png`。
- 真机恢复 HEVC/Sony MOV 后录制 `recording_20261011_095519`，位于 App Documents 根目录，只有 5 MB `clip.mov`；停录时间码归零。证据：CoreDevice `device info files` 和 `/Users/grape/project/ios_device_control/evidence/storage_saved.png`。设备构建 `/tmp/storage-adaptive-device-final.log` 通过；存储路径单元测试通过 `/tmp/storage-adaptive-tests.log`。该轮 UI 测试首次遇到模拟器无障碍服务 `kAXErrorServerNotFound`，单独重跑 `/tmp/storage-ui-retry.log` 通过。

## 09:22 本轮精简控件与方向验收

- iPhone 17 Pro（iOS 26.0.1）已安装最新构建；设备构建 `/tmp/recording-optimizations-device-postcap.log` 通过。真机 WDA 截图及元素树在 `/Users/grape/project/ios_device_control/evidence/optim-*.{png,xml}`。
- 顶部显示 `FHD / 30Hz / 1/500 / Auto`，点击最长曝光后显示详细名称和刻度；设置移到底部，去除前摄入口及顶部、底部灰色 HUD。竖屏与横屏的按钮均可读，横屏重复设置按钮已修复。
- 真机 HEVC/Sony MOV 录制 `recording_20261011_090336`：1920×1080、30 fps、23.17 秒，含 `rtmd` 数据轨；最终文件夹仅有 27.8 MB `clip.mov`。停录并完成保存后时间码回到 `00:00:00`。这段录制用于容器与布局检查，不用于增稳质量验收。
- 自动化界面改为竖屏后录制 `recording_20261011_090740`：HEVC、1920×1080 原生像素、30 fps、4.30 秒；MOV 显示矩阵旋转 90°，素材卡片显示 `1080×1920`。真机系统播放器显示竖屏完整画面；截图 `optim_preview2.png`。最终文件夹只含 `clip.mov`。横屏片段没有显示矩阵旋转。物理手持方向的持续运动与 Gyroflow 视觉对齐尚未验收。
- 模拟器素材预览在播放中横竖切换、关闭和删除测试通过：`/tmp/recording-preview-rotation-test.log`。横竖屏反复切换 UI 测试、方向/嵌入遥测单元测试通过：`/tmp/recording-optimizations-retest.log`、`/tmp/recording-orientation-final-test.log`；单元全集 `/tmp/recording-optimizations-unit-suite.log` 通过。
- 最后一次编码能力修正后，设备构建和模拟器单元全集再次通过：`/tmp/recording-optimizations-device-postcap.log`、`/tmp/recording-optimizations-final-units.log`。该版本已安装到 iPhone 17 Pro，并读回主界面准备状态。
- 新增 ProRes 422/422 HQ 后，真机实测当前 1080p30 与 4K30 的 `AVCaptureVideoDataOutput` 均只报告 `hvc1/avc1/jpeg`，无法以该输出录制 ProRes 422。现在按实际编码能力禁用这两个选项，避免产生失败素材；RAW/HQ 仍走已有外接存储路径。真机元素树 `optim_postcap_codecs.xml` 显示两个 422 选项 `enabled=false`。尚未验收其他镜头或格式组合的 422 支持。
- 未通过项：本轮没有明亮纹理运动片段，无法验收 Gyroflow 光学同步与增稳；RAW/HQ 的新方向映射、颜色与外置 SSD 录制也未重新实测。

## 竖屏布局修正 — 2026-10-11 05:54

- 再次通过 USB 操作 Blackmagic Camera 的竖屏 ISO、快门、白平衡：实际采用底部横向刻度与预设行。前一版沿用横屏右侧竖向面板，布局不符合参考，已修正。
- 竖屏独立底部参数面板，刻度左右滑动；预览上方为参数 HUD，下方状态信息保留独立空间。默认显示横向物理镜头栏，底部为录制按钮与摄影机/素材/设置导航。
- 横屏继续使用右侧竖向面板；相机采集、时间同步和文件输出未改动。
- 编译通过：`/tmp/portrait-layout-final-build.log`。
- 2 项布局/导航 UI 测试通过：`/tmp/portrait-layout-tests.log`。新增测试逐一检查六个参数面板的宽高、面板位于预览下方和录制按钮上方、关闭按钮和设置按钮可点击。
- 真机竖屏 ISO 400 预设实际读数约 399；横向拖动刻度后实际读数约 252，确认横向调节生效。已恢复自动曝光。
- 真机对照截图：`/Users/grape/project/ios_device_control/evidence/blackmagic-portrait-*.png`；修正后截图：同目录 `portrait-fixed-*.png` 和 `portrait-ruler-*.png`。
- 关灯状态下仅验收布局和控制读数，未验收画面质量。

## 参考来源

- 实际通过 USB WebDriverAgent 操作 iPhone 17 Pro 的 Blackmagic Camera 3.5.20，检查镜头、帧率、快门、ISO、白平衡、色调、编解码面板。
- 实测 ISO 刻度拖动改变读数；白平衡灯泡/日光预设改变温度与色调。结合用户提供的六张截图与指定 Bilibili 教程的参数操作画面： https://www.bilibili.com/video/BV1sApgzrEF1/
- 真机截图及 XML：`/Users/grape/project/ios_device_control/evidence/blackmagic-*.{png,xml}`。视频参考采样保存在 `artifacts/BlackmagicReference`，未纳入源码。

## 已实现

- 顶部单行六项参数：镜头、帧率、快门、ISO、白平衡、色调；选中项蓝色高亮。横屏中间显示录制时长，竖屏将时长放在参数上方。
- 点击参数后在取景器右侧展开竖向刻度盘，显示当前值浮窗、指示线和快捷预设。滑动结束吸附并应用所选值；顶部点选可切换/关闭。
- 快门速度/角度、ISO 快捷值、白平衡灯泡/荧光/日光/阴天预设、色调正负值。自动曝光保留最大曝光时间菜单。
- 快门与 ISO 共用自动/手动曝光状态；进入手动时保留另一项的实际值。温度与色调共用自动/锁定状态，保留另一项实际值。
- 实时控制通过相机会话队列更新设备，无需重建预览。录制中固定镜头和帧率；RAW 录制中锁定白平衡控制。
- 设置提供 H.264、H.265/HEVC、ProRes RAW、ProRes RAW HQ；分辨率和设备支持的 Rec.709、P3、HLG、Apple Log。H.264 不提供 HLG/Log；RAW 保留传感器和 Apple 原生写入元数据。
- 每段独立文件夹、三种遥测输出、IMU 前后采集及平均曝光时间补偿保留。

## 编译与自动化测试

| 项目 | 结果 | 证据 |
|---|---|---|
| iOS 真机目标编译 | 通过 | `/tmp/camera-dial-final-build.log` |
| 单元测试 21 项 | 通过 | `/tmp/camera-dial-acceptance.log` |
| 六个参数面板打开/关闭 | 通过 | 同上，`testCameraParameterPanels` |
| 设置与素材导航 | 通过 | 同上，`testCameraNavigation` |
| 最新代码安装到 iPhone 17 Pro | 通过 | installationURL 容器 `C532D4CE-A77D-4E57-97B6-7B650775FCCD` |

测试结果：`artifacts/OutputModesSim/Logs/Test/Test-RawMotionRecorder-2026.10.11_05-27-11-+0800.xcresult`。
初次面板测试发现父容器标识覆盖关闭按钮标识，已使用 `accessibilityElement(children: .contain)` 修复并重新运行全部上述测试。

## 真机操作结果

设备：iPhone 17 Pro，iOS 26.0.1。取景场景关灯，仅验收控件与设备读数。

- 六个参数入口与面板可打开；横屏、竖屏均已取得截图。
- ISO 400 预设：设备读数约 399–400；竖屏刻度拖动后读数约 1598，对应选中 1600。设备量化后的读数显示在 HUD。
- 快门 1/120 预设：后续 HUD 读数为 1/120，预览会话保持运行。
- 日光 5600K：后续 HUD 温度为 5600K；色调 0 预设后读数为 0。
- 自动曝光可恢复；未为本次 UI 验收录制黑暗视频。
- 证据：`/Users/grape/project/ios_device_control/evidence/rawmotion-*.{png,xml}`。

## 尚未验收

- 明亮场景下的手动色彩、曝光视觉效果，以及录制中实时调节的最终视频结果。
- 新编码/色彩空间组合的实际 MOV 编码标记、颜色解码与 Gyroflow 增稳。
- RAW/HQ 的彩色增稳导出仍需独立验证。界面测试通过不代表该问题解决。

## 后续真机验收步骤

1. 明亮有纹理场景，H.265 / Rec.709 / 1080p30；选择 1/120、ISO 400、5600K、色调 0，录制 20 秒缓慢运动。
2. 记录过程中调整 ISO 与快门，观察 HUD 与最终视频；检查帧曝光元数据和时间轴，确认无会话重启、异常帧间隔。
3. 自动模式选择最大 1/120，确认各帧曝光未超过上限。以原始日志与 MOV PTS 核对时间映射。
4. 每种物理镜头分别重复；验证 RAW/HQ 时接入 SSD，检查 `aprn` / `aprh` 和实际色彩解析。

## 2026-10-11 横竖屏切换修正

- 相机预览移到横竖屏分支之外，旋转时保留同一个 UIView / capture preview layer。
- 根布局与取景器显式跟随可用尺寸，裁剪越界内容，关闭布局隐式动画。
- 预览角度只在改变时更新，并禁用该层隐式动画。视频与 IMU 采集流程未修改。
- 设备构建通过：`/tmp/rotation-build.log`。
- UI 自动化 2/2 通过：`testRepeatedCameraRotation`（面板关闭/展开，左右横屏及竖屏共 8 次切换）、`testPortraitControlsStayBelowPreview`。日志 `/tmp/rotation-tests.log`；结果 `artifacts/OutputModesSim/Logs/Test/Test-RawMotionRecorder-2026.10.11_06-07-46-+0800.xcresult`。
- 安装到 iPhone 17 Pro 成功，安装容器 `182DC376-608A-473D-A143-95E161866CB8`。WDA 真机执行 8 次切换，截图保存在 `/Users/grape/project/ios_device_control/evidence/rotation-fixed-*.png` 和 `rotation-fixed-panel-*.png`。
- 边界：截图确认切换后的完整布局；旧版稳定状态也未复现半屏，尚未通过逐帧录像确认用户遇到的瞬时半屏或量化动画流畅度。暗室未验收预览画面质量。

## 2026-10-11 全屏预览与悬浮控件

- 单一预览放到最底层，覆盖安全区域；使用 aspect fill，预览裁边但不更改录制画幅。参数展开不改变预览尺寸。
- 薄荷绿选中态、圆角半透明面板；竖屏合并素材/录制/设置操作行。
- 设备构建通过 `/tmp/overlay-build.log`，自动化 3/3 通过 `/tmp/overlay-tests.log`：完整预览覆盖、六类参数面板、反复横竖屏、设置/素材导航。结果 `artifacts/OutputModesSim/Logs/Test/Test-RawMotionRecorder-2026.10.11_06-11-26-+0800.xcresult`。
- 已安装 iPhone 17 Pro，容器 BEC05EBC-232C-4478-9963-5E4239121BC0。WDA 核对 preview 边界：竖屏 (0,0,402,874)，横屏 (0,0,874,402)，展开 ISO 后四次旋转仍全屏。截图 `/Users/grape/project/ios_device_control/evidence/overlay-*.png`。
- 暗室仅验收 UI 与预览视图边界，明亮场景下的预览裁切观感未验收。

## 2026-10-11 第一版界面精简

- 顶部保留分辨率、帧率、最长曝光、白平衡；移除 ISO/色调/顶部镜头，底部保留物理镜头切换。
- 参数面板改为直接点选。最长曝光调用 setExposureLimit，强制 manualExposure=false；初始化 CameraControls 默认自动曝光/自动白平衡，没有持久化旧手动 ISO。
- 隐藏色彩空间、容量、IMU 计数和诊断状态栏，保留保存中与错误提示。设置只保留编码、适用的色彩空间、声音、保存格式。
- 真机构建 `/tmp/simple-build.log` 通过，安装容器 B11C0E5B-E544-4137-826F-58F2DBD67D16。
- `/tmp/simple-tests.log` 中全屏参数、旋转、导航三项通过；精简界面测试最初错误假设模拟器有 1/120 相机规格而失败。改为能力无关断言后 `/tmp/simple-retest.log` 通过。共四项测试通过（分两次执行）。
- 真机 WDA 点选 1/240 秒，顶部正确更新为 1/240，设置仅四项；证据 `/Users/grape/project/ios_device_control/evidence/simple-limit-240.png`、`simple-settings.png`。本轮验证 UI 及参数选择，未重新录制验收传感器曝光值或 Gyroflow 同步。

## 2026-10-11 悬浮控件、前摄及素材管理

- 移除顶部独立分辨率/IMU 徽标；镜头按钮 52pt 圆形，去除下方整条底板。设置移到右上，原底部位置为前后摄切换；录制时禁止切镜头。
- 四类参数恢复居中吸附滑动刻度：竖屏水平、横屏垂直，停止滑动后应用；曝光仍是自动 ISO 的最长曝光上限。前摄筛选物理广角，RAW 不支持时回退 HEVC。
- RAW 设置每秒检测外接设备连接、权限与剩余空间；录制仍执行原有外接存储授权与容量检查。当前 RAW 通路要求 SSD，不宣称支持内置存储 RAW。
- 素材缩略图、系统播放器预览、添加到图库（仅添加授权）、删除整个文件夹二次确认。失败保留原文件；不支持的格式显示说明。
- 构建 `/tmp/media-delivery-build.log` 通过。4 项布局/导航回归 `/tmp/media-tests.log` 通过；专用模拟器素材预览与删除 `/tmp/media-fixture-retest.log` 通过（第一次因两个完成按钮歧义失败，加独立标识后通过）。测试结果 `artifacts/OutputModesSim/Logs/Test/Test-RawMotionRecorder-2026.10.11_07-57-12-+0800.xcresult`。
- 真机确认滑动曝光值变化、前摄预览打开及后摄恢复；截图 `/Users/grape/project/ios_device_control/evidence/media-front.png`、`media-back-ready.png`、`media-landscape.png`。
- 本轮 HEVC 测试录制 `recording_20261011_074839`（约24秒，包括自动化操作开销）保存图库收到系统 PhotoKit 成功回调，截图 `media-final-save.png`。图库副本保留；随后真机删除了本轮测试文件夹 `recording_20261011_074839`，既有用户素材未删除。模拟器也验证了 `recording_ui_fixture` 删除。
- 未验收：RAW/SSD 热插拔、RAW 播放/图库兼容性、前摄视频与 IMU 坐标/同步质量。HEVC 的图库保存不代表 RAW 支持。

### 最终补验（08:15）

- 最终设备构建 `/tmp/controls-final-build.log` 成功并安装 iPhone 17 Pro，容器 `64FE0D53-40A1-4DE9-8EDE-4D7445824F38`。
- 最终 4 项 UI 回归全部通过：参数界面、反复旋转、竖屏全屏预览覆盖、相机导航。日志 `/tmp/controls-final-tests.log`；结果 `artifacts/OutputModesSim/Logs/Test/Test-RawMotionRecorder-2026.10.11_08-14-24-+0800.xcresult`。
- 真机 RAW 选项出现“未检测到 SSD，RAW 录制需要外接存储”，证据 `final-raw-selected.png/xml`；之后恢复 HEVC。尚未连接 SSD 验证热插拔。
- 横屏最长曝光竖向拖动从系统默认更新为 1/48，证据 `final-ruler-drag.png/xml`。竖屏完整布局 `final-portrait.png/xml`。
- 修复播放器初始化：创建页面时建立 AVPlayer，并交给 AVPlayerViewController。真机 `player-init-controls.png` 显示既有明亮 HEVC 片段实际画面与播放控件；未据此验收 RAW 解码或连续播放质量。
- `verify-delete-confirm.png` 显示整个录制文件夹删除确认；`verify-deleted.png/xml` 确认本轮测试文件夹消失、既有素材仍存在。
- 上述截图位于 `/Users/grape/project/ios_device_control/evidence/`。复测：素材→预览；素材操作→保存到图库；仅用测试素材执行删除确认。RAW 存储测试需另接 SSD，观察设置提示随连接状态更新。
# 2026-10-11：存储与控制界面六项调整

## 即时提示修复

- SSD 选择现在区分无盘、首次授权、权限已拒绝、容量不足、文件访问失败和 App 文件夹写入失败。首次授权交由 iOS 原生弹窗；无盘 UI 测试通过 `/tmp/rawmotion-ssd-alert-ui.log`，SSD 接入与授权流程待接盘验证。视频编码选项移除 H.264，单元测试通过 `/tmp/rawmotion-hide-h264-test.log`；设备构建 `/tmp/rawmotion-ssd-alert-build.log` 成功并安装到 iPhone 17 Pro。
- 设置页中的视频编码、色彩空间、录制位置、保存格式均改为锚定在对应设置行的弹出选单，选项不会额外占据表单行。无效 SSD 选择的提示直接显示在选单上。
- 弹出选单模拟器 UI：设置导航、SSD 即时提示通过（`/tmp/rawmotion-popover-tests.log`）；保存格式选择和重启持久化通过（`/tmp/rawmotion-popover-output-retest.log`）。真机构建 `/tmp/rawmotion-popover-build.log` 成功并安装到 iPhone 17 Pro。RAW 选项仍需在真机上单独交互确认。

- SSD 位置改为检测外置盘、请求系统授权并尝试在磁盘根目录创建 `RawMotionRecorder`。未连接磁盘或根目录不可写时弹出明确错误；不再出现文件夹选择器。外置 SSD 当前未连接，根目录写入和 RAW 录制仍待真机实测。
- 选择 ProRes RAW / RAW HQ 时先检查录制位置是否为 SSD；未设置时维持原编码并提示。录制开始时仍二次检查连接、授权、可写目录和容量。
- 保存格式按产品文案更名；分辨率徽标区分 Gate、4K、HD。横屏镜头和设置/素材控件顺序调整。
- 参数滑尺选值后等待约 2 秒关闭；相机重配置不再立即关闭滑尺。手动关闭或再次滑动会取消计时。
- iPhone 17 Pro：设备构建 `/tmp/rawmotion-six-changes-build-final.log` 成功；CoreDevice 安装和启动成功。模拟器相关单元测试 26 项通过，参数面板 UI 测试通过（`/tmp/rawmotion-six-focused-tests.log`）；保存格式选择与重启持久化 UI 测试通过（`/tmp/rawmotion-outputmode-ui.log`）。模拟器全量测试中，依赖真实相机就绪的录制用例失败；SSD 根目录写入、RAW 实录和横屏实体操作尚未验收。
