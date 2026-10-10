# RoamShot 风格界面验收 — 2026-10-10

## 改动

参考 `/Users/grape/project/ios_action_camera/App/Views/CameraView.swift` 与 `AppTheme.swift` 的布局和配色：全屏取景、顶部品牌/格式/设置、底部主摄 1× 与圆形录制键、素材页、深蓝背景与青绿色强调色。保留 RawMotion 的独立项目和采集模块，只提供当前已实现的固定主摄 HEVC + IMU 功能。

## 已验证

- iPhone 16 / iOS 18.2.1：XCTest 5/5，Settings/Library 导航 UI 测试及 20 秒录制 UI 测试 2/2，于 20:00 CST 通过。
- 本次实际 22.4653 秒、674 帧、4516 IMU 事件，AAC 存在；674/674 帧有 API K。
- `video_samples.jsonl` 每条记录绑定成功写入的视频样本 source PTS、native buffer 坐标 K 与 activeVideoStabilizationMode（实测全为 0/off）。对应 MOV 实际帧数一致，最大 PTS 映射残差 0.8328ms。此结果不能证明曝光级同步或 OIS 关闭。
- 图像检查发现预览方向未固定；补充 portrait 90° preview-only rotation，录制 buffer 和 K 保持 native 0°。
- 上述最后的预览方向修正后，模拟器 XCTest 5/5 + 导航 UI 1/1 于 20:07 CST 通过；真机再次离线，**最后方向修正的真机视觉复测未通过/待验证**。设备当前安装的是本次 20 秒测试版本。

## 证据

- `artifacts/test_logs/roamshot_ui_device20.log`
- `artifacts/test_logs/roamshot_ui_simulator.log`
- `artifacts/test_logs/roamshot_ui_final_simulator.log`
- `artifacts/test_logs/roamshot_ui_final_device.log`（设备离线，不能计为通过）
- `artifacts/device_runs/roamshot_ui20/screenshots/manifest.json` 与 PNG
- `artifacts/device_runs/roamshot_ui20/recording_20261010_195957/`
- `artifacts/device_runs/roamshot_ui20/validation.json`

再次连接后安装当前工程，仅复测导航/预览，无需再进行长录制。分享按钮文件夹到 Files 的实际接收结果仍待用户设备端验证。
