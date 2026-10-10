# Task 0 — 2026-10-10

- 新独立 Xcode 工程、模块架构、主摄预览、Settings、权限与运行时 4K30 能力扫描已实现。
- 用户批准 M1 deployment target 为 iOS 18.2；Xcode 26.3。
- simulator 构建成功、初始 XCTest 3/3 通过。
- 签名真机构建、安装、启动通过；iPhone 16 / iOS 18.2.1 实际进入 Ready，UI 自动化可录制，最终 MOV 确认主摄 4K30。
- 最终真机 XCTest 4/4 通过。Settings 各选项行为和权限拒绝路径待单独验收。
- 详见 M1_REPORT.md。

RoamShot-style full-screen UI and Settings/Library sheets now implemented. Device navigation and20s capture passed; API K/source timing added. See UI_REPORT.md for the final preview-only direction fix and device-offline limitation.
