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

## 2026-10-16 iPhone19,7 / iOS 27.0.1 investigation

- Device registered and Debug installed using a device-specific development profile via ideviceinstaller; Xcode 26.3 DDI cannot mount on this device, so launch/capture testing is manual pending Mac/Xcode upgrade.
- Retrieved Documents/Log through House Arrest/AFC. Session 35FA56E1-9CDE-40ED-A38D-D1A7C21F81B8 reports 150000001024 bytes reserved capacity, output support true for H.265 3840x2160/30, and a completed short local MOV.
- Changing to RAW/aprn or RAW HQ/aprh at format 61, 4224x2240/30 results in the output-support guard rejecting recording. User confirms cold launch directly into RAW also fails. This is not proven to be a capacity failure or a missing selector.
- Diagnostic build records device/output support, selector presence, enabled state, capacity, busy state, SDK, rotation, camera configuration, and session state before stopping RAW, while stopped, after storage preparation, after starting, and around record orientation changes. It tries enabling storage before starting the RAW session only when the system reports support. Existing preflight safety check remains.
- Error dialog now includes codec, dimensions, fps, device/output support and remaining capacity. Build/install alone does not establish a fix; awaiting manual RAW capture and diagnostic retrieval.
- Manual retest of diagnostic build still fails. Session BB96C7B7-1F34-4837-8EEE-E5D4DED98120: device=true, selector getter/setter present=true, busy=false, remaining=149905383424, uses=false; output support is false before/after RAW session stop/start and around record rotation for 4224x2240/30 and 4224x3024/23.976. Thus configuring after selecting RAW but before session start did not resolve the issue. Linked SDK is iphoneos26.2; any SDK gating remains unproven.
- Next controlled build also attempts destination opt-in before changing the sensor format and encoder, only when support is true. Added format-before/after diagnostics. Manual HEVC-to-RAW transition is required to test this order. Do not report RAW internal capture as fixed before actual MOV evidence.
- Second controlled test also fails (session 2646A767-8DA4-41F0-B198-AC51BE8D332B). Before the RAW change the actual encoder is hvc1, outputSupported=true, usesProVideoStorage=true; immediately after setting aprn, outputSupported=false while usesProVideoStorage remains true. It stays false through stop/start and recording preflight. This rejects the attempted early-opt-in workaround for the tested configuration.
- Removed both unsuccessful early-enabling experiments from source, retaining diagnostic logs and detailed errors. No support guard bypass was introduced. The installed phone version is still the order-test build. Next discriminating test: build with actual iOS 27 SDK and compare a minimal movie-only capture session against current movie+intrinsics session. Neither SDK gating nor an OS-wide RAW limitation has been established. Mac/Xcode upgrade currently blocks that comparison.
- Cleanup build compiled and reinstalled successfully after removing the failed order experiments; device now has diagnostic-only changes, not the early-opt-in experiments. RAW internal recording remains unresolved.
