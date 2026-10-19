# TestFlight RAW 长录制豁免修复 · 2026-10-19

- 旧版 1.0 (20261019.6) 虽启用了测试豁免开关，但还要求旧式 `sandboxReceipt` 文件存在；用户通过 TestFlight 安装后仍遇到 2 分钟付费提示。
- 1.0 (20261019.7) 改为直接读取 Apple 签名的 `AppTransaction`。只有交易验证成功且环境为 Sandbox 时，RAW／RAW HQ 才跳过 120 秒限制；生产环境仍执行免费限制。
- 1.0 (20261019.8) 在测试豁免生效时，设置页改为显示「RAW 长录制已开放」，Pro 页面不再显示 2 分钟付费文案或购买按钮；正式版购买入口不变。
- App 回到前台时重新检查签名交易。验证失败时保留 2 分钟限制并写入 `ProAccess` 系统日志，便于定位。
- `ProAccessTests` 模拟器回归：2 通过、1 跳过（需要 CommerceQA 的本地购买测试）。Release 归档编译通过，构建号 20261019.7。
- 20261019.7 已加入内部测试和熟人测试群组。实际 TestFlight 安装并录制超过 2 分钟仍需验证；本地安装的开发包不能证明 Apple 签名的 TestFlight 环境行为。
- 用户确认 20261019.8 已通过 TestFlight 安装，仍显示 2 分钟付费提示；设备构建号也核对为 20261019.8。因此 `AppTransaction.environment` 未在该设备上触发豁免，前两版修复不能视为通过。
- 20261020.1 改用 Apple 的 `MarketplaceKit.AppDistributor.current` 直接判断安装来源。仅 `.testFlight` 且构建开关开启时豁免；`.appStore` 等来源继续执行 120 秒限制。识别结果写入 App 私有 Application Support 的 `pro_access.json`，便于从真机拉取证据。
- 20261020.1 的真实 TestFlight 安装、权限显示及超过 2 分钟 RAW 录制仍需回归。

## 独立免费测试构建（20261020.2）

- 用户要求 TestFlight 版本不显示、也不执行付费功能。`TESTFLIGHT_FREE` 编译条件使 RAW 录制权限始终开放，即使 StoreKit、安装来源检测或网络不可用，也不会启动 120 秒停止计时器。
- 测试构建隐藏设置中的 Pro 购买入口，并从编译结果中移除购买、恢复购买方法和付费页面。设置页底部显示测试版标识。
- 标准 Release 构建不开启此条件，继续执行付费规则。项目默认的 TestFlight 豁免开关为 `NO`；免费测试构建使用 `scripts/upload_testflight_free.sh` 单独归档和上传。
- 该免费构建仅分发到 TestFlight 群组，不得选作 App Store 正式版审核构建。`20261020.1` 已上传但不分发；`20261020.2` 已上传并加入“熟人测试”群组，App Store Connect 显示“正在测试”。
- `TESTFLIGHT_FREE` 下 `ProAccessTests`：3 通过、0 跳过；标准 Release 构建通过。归档内 `GyroCineTestFlightFreeBuild=YES`。真实 TestFlight 安装与超过 2 分钟 RAW 录制仍待设备验证。
