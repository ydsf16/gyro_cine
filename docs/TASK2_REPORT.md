# Task 2 — 2026-10-10

**格式验证通过，Gyroflow 端到端验收未通过。**

- 使用固定官方 gyroflow.proto，commit 8bd825db33700c4d4472fae61eada27a65aea7a8；实际 encoded sample / PTS 驱动逐帧 JSONL，数字类型和 1..N 帧序。
- 真机 MOV/JSONL validator 通过；官方 JSONL → Protobuf → JSONL 往返保留 675 帧和 4521 IMU 事件。
- 真机 XCTest 4/4、桌面 validator 自动化 3/3 通过。
- 未知硬件 readout、OIS、镜头和轴标定字段未编造。
- Gyroflow 1.6.3 手动 JSONL 导入报 Unsupported file format。最新 parser 存在缺失硬件时间字段默认 0 的时间语义限制。
- 官方开发版 1.6.3 (gh2733) 自动关联及运动数据读取通过；parsed metadata 实证错误的 per-frame offsets（从 0 递减至 −22.465 秒）。有效运动时间轴、离线同步和实际增稳导出均待验收；不能据格式解析成功标记 M1 通过。详见 M1_REPORT.md。

Separate offline-sync workaround now runs with original raw gyro samples, producing three measured offsets and a674-frame4K stabilization candidate. Native JSONL semantics remain unresolved. User has deferred RS correction from M1; see ISSUE_RESOLUTION.md.
