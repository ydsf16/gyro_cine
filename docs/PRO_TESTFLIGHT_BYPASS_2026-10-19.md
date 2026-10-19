# TestFlight RAW 长录制豁免修复 · 2026-10-19

- 旧版 1.0 (20261019.6) 虽启用了测试豁免开关，但还要求旧式 `sandboxReceipt` 文件存在；用户通过 TestFlight 安装后仍遇到 2 分钟付费提示。
- 1.0 (20261019.7) 改为直接读取 Apple 签名的 `AppTransaction`。只有交易验证成功且环境为 Sandbox 时，RAW／RAW HQ 才跳过 120 秒限制；生产环境仍执行免费限制。
- App 回到前台时重新检查签名交易。验证失败时保留 2 分钟限制并写入 `ProAccess` 系统日志，便于定位。
- `ProAccessTests` 模拟器回归：2 通过、1 跳过（需要 CommerceQA 的本地购买测试）。Release 归档编译通过，构建号 20261019.7。
- 实际 TestFlight 安装并录制超过 2 分钟仍需验证；本地安装的开发包不能证明 Apple 签名的 TestFlight 环境行为。
