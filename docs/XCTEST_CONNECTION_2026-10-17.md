# XCTest 真机连接恢复（2026-10-17）

## 验证结果

- iPhone 18 Pro Max / iOS 27.0.1，Xcode 27.1。
- `IMURecordingUITests/testEnglishDeviceScreens` 真机通过：1 项，0 失败，10.60 秒。
- 实际完成打开 Settings、关闭 Settings、打开 LUT、保存两张截图。
- LUT 截图确认 `Amber` 和 `Preview only` 为英文。
- 此次只验证 UI 自动化连接，不代表录制或画面质量回归。

## 故障与处理

原始错误：`Connection peer refused channel request for dtxproxy:XCTestDriverInterface:XCTestManager_IDEInterface`，随后 runner 退出 code 74。测试方法尚未执行。

1. Mac 默认 `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`。管理员授权后切换到 `/Applications/Xcode.app/Contents/Developer`，解决诊断阶段找不到 devicectl 的问题；单独切换未解决握手失败。
2. 手机连接 USB，devicectl 确认 `Transport Type: wired`；单独切 USB 仍失败。
3. 确认没有正在运行的 xcodebuild 后，对当前用户的 `CoreDeviceService` 发送 TERM，让系统重新启动服务。服务重启会短暂断开本机的设备调试连接，不应在其他设备任务运行时执行。
4. devicectl 确认 USB 隧道地址变化；复用原构建立即成功。没有重装/删除 App 数据，没有重启手机，也没有修改业务代码。

证据指向设备连接服务/隧道残留状态；未确定更底层根因。未重新验证纯 Wi-Fi。

## 已通过命令

```sh
xcodebuild test-without-building \
  -project gyro_cine.xcodeproj -scheme GyroCine -configuration Debug \
  -destination 'platform=iOS,id=00008160-000A6CEA3E40000A' \
  -derivedDataPath /tmp/gyrocine-localization-device \
  -only-testing:GyroCineUITests/IMURecordingUITests/testEnglishDeviceScreens \
  -parallel-testing-enabled NO \
  -resultBundlePath /tmp/gyrocine-xctest-fresh-tunnel.xcresult
```

以上命令要求对应 DerivedData 已完成 build-for-testing；结果路径不得重复使用。

## 本机证据

- 成功日志：`/tmp/gyrocine-xctest-fresh-tunnel.log`
- 结果：`/tmp/gyrocine-xctest-fresh-tunnel.xcresult`
- 截图：`/tmp/gyrocine-xctest-success-screens/`
- USB 旧隧道失败：`/tmp/gyrocine-xctest-usb.xcresult`
- 修正全局工具路径后、重启服务前失败：`/tmp/gyrocine-xctest-selected.xcresult`
