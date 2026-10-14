# Pro Video Storage TestFlight check

Build: GyroCine 1.0 (20261014). The runtime adapter uses iOS 27 AVFoundation selectors so the app can still be built with Xcode 26.3. On iOS 26 and earlier, selecting Pro Video Storage must show an unsupported message.

## iOS 27 device checks

1. In Settings > Storage, select **Pro Video Storage**. If the reserved capacity is zero, use **Open Pro Video Storage Settings** to allocate it in iOS Settings, then reopen GyroCine.
2. Select a supported physical lens, ProRes RAW or RAW HQ, resolution and frame rate. Record at least 10 seconds without an SSD; stop and wait for finalization.
3. In Media, confirm the `IMG_*.mov` clip is present, plays with audio, and shows the green IMU badge. In Files, confirm the MOV is under `GyroCine/Media` and diagnostics under `GyroCine/Log`.
4. Record a second clip and verify that the reserved capacity has not become unexpectedly unavailable. Also test the zero-capacity, busy-storage, and unsupported-format prompts if those states occur.
5. Switch to **Internal Files**, keep ProRes RAW selected, and tap Record. Confirm the app asks for Pro Video Storage or external SSD before starting.
6. Switch to **External SSD** and confirm the existing RAW path still records. Then switch to HEVC/Internal Files and confirm local recording still works.

For each failure, save the exact iPhone model, iOS version, codec, format, frame rate, storage choice, on-screen error, and the app's `Log` files. A successful build or a green IMU badge alone does not establish that the iOS 27 RAW storage path works; inspect the MOV's video, audio, and embedded telemetry tracks.
