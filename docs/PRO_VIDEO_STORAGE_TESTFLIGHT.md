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

## Native SDK follow-up

- macOS 27.0.1 and Xcode 27.1 (27A9275), iOS SDK 27.1 are now installed. Device support recognizes iPhone19,7 correctly and devicectl install/launch works.
- Built and installed the existing selector-based implementation unchanged against SDK 27.1 as a comparison build; no capture result was collected for that build.
- Checked the SDK headers: AVProVideoStorage.sharedStorage/isSupported, remainingCapacity, busyReasons, openSettings and AVCaptureMovieFileOutput.isProVideoStorageSupported/usesProVideoStorage match the previous selectors. These APIs are available from iOS 27.0, not exclusive to 27.1.
- Replaced dynamic selectors/function-pointer calls with typed public SDK calls guarded by @available(iOS 27.0, *). Added initial capacity, busy reasons and native binding marker to diagnostics. Debug build succeeds; minimum deployment remains iOS 18.2. Physical RAW dedicated-storage success remains pending; this change does not bypass output support checks.
- Native SDK manual failure confirmed in session 5B396E97-3AA8-47E4-9AF5-E89CD5216914: RAW 4224x2240 at both 60/30 fps returns outputSupported=false, deviceSupported=true, 150GB remaining, no busy reasons.
- Automated DEBUG support probe session CF1021F3-BF62-427A-9B25-828B9FE01333 (RAW/30): removing intrinsics output, restarting, removing audio input, and reducing output settings to only aprn each still return false. These are sequential changes to an existing session, not a fresh movie-only session; a fresh-session control remains necessary. No recording or user-media deletion was performed. Probe is opt-in via --pro-storage-support-probe; normal launch restores production configuration.

## Standalone probe findings (2026-10-16)

A separate `com.tinygrape.ProStorageProbe` app lives under `tools/ProStorageProbe` (generate with XcodeGen). It does not import GyroCine code. Camera is the physical wide-angle, 30fps, no preview/audio/IMU/K/production controls. Logs go to its Documents, recordings are UITEST_writer_*.mov. Test files are retained.

- Fresh MovieFileOutput: RAW/aprn at formats 67,68,71 and HQ/aprh at 67,71 all report Pro Video Storage unsupported. A follow-up disables deferred start, locks WB with the explicit gains API and waits for its effective-time callback; support remains false afterwards.
- AssetWriter with native raw VideoDataOutput: writer support is true both before and after adding the RAW input. Enable `usesProVideoStorage` before `startWriting`.
- `recommendedVideoSettings(...outputFileURL:)` throws for both a local URL and nil URL: “Capturing ProRes Raw codec is supported only on external storage device.” The overload WITHOUT outputFileURL returns valid RAW settings. These are separate API calls, not equivalent nil arguments.
- Setting WB mode to locked, or calling gains lock before the first frame, still led to asynchronous writer failure -11891. Waiting until a real camera frame arrives, calling `setWhiteBalanceModeLocked(with:completionHandler:)`, and accepting frames only after that callback produced successful recordings.
- RAW 5-second clip `UITEST_writer_0B6E1CFE-A2A2-4254-A217-136520A65588.mov`: aprn, 4224x2240, 150 frames, 5.033333 seconds, ~636MiB. Full ffmpeg decode passes. MOV PTS has one 66.667ms gap (one missing frame period), so do not describe cadence as perfect; writer backpressure count is zero.
- First HQ30 attempt stopped delivering after ~25s and later reported -11847 Operation Interrupted. Auto-lock was not disabled in that build; lock/background causation is plausible but was not captured as a notification and is not established.
- HQ30 repeat with idle timer disabled: `UITEST_writer_62FE5522-3EC4-455D-9140-D8252252B0F2.mov`, 900 frames, writer completed, no backpressure drops. File-level verification is recorded below when complete.
- Evidence logs and first clip inspection are under `artifacts/prostorage-20261016`. The successful prototype has video only: audio, embedded IMU, per-frame K, preview, autofocus switch behavior, background recovery, sustained thermal/long-capture behavior remain integration tests. No production recording route has been replaced.
- HQ30 file verified as aprh/RAW HQ, 4224x2240, 30.033333s, 900 frames (~5.3GiB). Packet PTS has one 66.667ms gap. It is a valid completed recording, but not drop-free.
- A further RAW repeat produced `UITEST_writer_DA11972F-4903-4C3A-83C6-AA4D2832D0F9.mov`: aprn, 4224x2240, 5.033333s, 151 frames, maximum PTS gap 33.334ms and zero gaps over 1.5 frame periods. No backpressure drops.
- Final standalone app includes an on-screen RAW recording test button and is installed alongside GyroCine. Original production recording code has not been migrated to AssetWriter; a deliberate integration needs audio, preview, K/IMU synchronization, error recovery, and autofocus regression validation.
- Full ffmpeg video decode completed successfully (exit 0, empty error log) for all three successful clips: RAW5, HQ30, and RAW5 repeat. This validates recorded RAW video decoding on this Mac, not audio/IMU or Gyroflow stabilization.

### GyroCine integration experiment (2026-10-16)

Opt-in DEBUG flag `--raw-writer-integrated-experiment` routes only RAW/RAW HQ + dedicated storage to `RAWInternalWriterExperiment`. Existing camera session/preview/device configuration are retained; movie/K outputs are temporarily replaced with native RAW output, then restored. The experiment intentionally delivers **video only**, without audio, IMU, K, or orientation transform; it is not the production recorder replacement. H.265 and SSD routes are unchanged. UI blocks lens/spec changes during the experiment. `--raw-writer-integrated-auto` selects main wide 4224×2240/30 and records 10 seconds; `--writer-hq` selects HQ.

On iPhone 18 Pro Max / iOS 27.0.1:
- Initial RAW: 302 frames, 10.101667 s, one 66.67 ms gap caused by encoder initialization on capture callback queue; writer backlog peak 1.
- Revised encoder preparation: create/start writer before choosing the next delivered frame as the recording start. Original source timestamps are preserved. Preparation losses are reported separately, not counted as recorded frames or concealed by retiming.
- Revised HQ: 302 frames, recording capture drops 0, preparation drops 1, max recorded PTS gap 33.334209 ms, backlog peak 1.
- Revised RAW: 303 frames, recording capture drops 0, preparation drops 0, max recorded PTS gap 33.33425 ms, backlog peak 1.

Bounded queue retains at most 3 source sample buffers, retries Writer readiness without blocking capture, and stops with an explicit error if capacity is exceeded. This bounds memory, but does not establish that buffering fixes sustained throughput deficits. No backpressure occurred in these trials; pool starvation and overload behavior remain unvalidated. Finish drains pending samples with a bounded readiness wait. Long capture, interruption/recovery, orientation, audio, IMU/K and autofocus visual regressions remain pending before production enablement.

Evidence: `artifacts/prostorage-20261016/integrated/`; experiment MOVs retained in phone Media and `/tmp/gyrocine-writer-{first,hq,raw2}.mov` on Mac. Filenames start `UITEST_IMG_writer_`; UI reports video-only experiment. Nothing committed or pushed in this experiment.

File-level checks: revised RAW `aprn` 4224×2240, 303 frames / 10.100000 s; revised HQ `aprh` 4224×2240, 302 frames / 10.066667 s. Both MOV packet PTS sequences have max gap 0.033334 s and zero gaps >50 ms. Initial RAW and revised HQ full ffmpeg decode completed with exit 0 and empty error logs.
Revised RAW full ffmpeg decode also completed with exit 0 and an empty error log. All three integration experiment movies fully decoded successfully.

### Full-chain RAW Writer experiment and early WB lock (2026-10-16)

The DEBUG experiment now includes AAC audio, IMU pre/post-roll, K captured from the **same native RAW sample buffers**, the existing durable PendingIMUJob/finalizer, and gravity-derived track transform. The same PTS/session synchronization clock maps the first video frame to host/IMU time. Source IMU axes stay sensor-native; MOV display rotation and lens-profile output dimensions carry orientation. No post-capture video re-encoding is introduced. Experiment activation is retained under `debug.rawInternalWriterExperiment` for manual relaunches of the installed Debug app; Release still uses the original production recorder.

Problems found and addressed:
- Initial 120fps trials recorded video but raised AVFoundation -11872 while configuring/restoring MovieFileOutput plus the old full-raster K output. These trials are NOT accepted as healthy end-to-end runs. Removed the redundant K output from the RAW Writer preview/configuration route.
- Recurring WB completion-handler timeout: actual video/audio arrived, IMU was ready, but an explicit gain-lock callback did not return. Advancing blindly or using a fixed wait was rejected. RAW mode now attaches persistent native video/audio outputs and locks **current** WB in live preview, before REC. Recordings reuse the ready preview and do not relock WB or rebuild the capture graph at every REC/Stop. Format/lens changes invalidate and prepare a new preview. Manual WB remains locked; Auto WB is blocked in this RAW route.
- Audio output recommendations initially produced LPCM; explicitly selected AAC at source sample rate/channel count (observed 48kHz mono), with bounded audio buffering.
- Corrected telemetry timing provenance to VideoDataOutput for Writer recordings. K snapshots are copied as small value objects to the metadata queue; no extra pixel-buffer retention for K.

Latest preview-retention build tests (iPhone 18 Pro Max, iOS 27.0.1, 4224×2240):
- RAW 120fps / portrait / GyroflowProto: **three consecutive 5-second recordings in one App session**, 604, 605, 605 frames. All completed audio/IMU/K finalization; capture drops 0 in each; no runtime errors or WB timeouts. Backlog peak 1 of the 3-frame limit.
- RAW HQ 60fps / landscape / SonyMov: 302 frames, audio/IMU/K complete, capture drops 0, no runtime error.
- RAW 30fps / landscape / SonyMov: 152 frames, audio/IMU/K complete, capture drops 0, no runtime error.
- Device capability enumeration offered `aprn` only on 120fps RAW format 68; HQ was not tested at 120fps because it was not offered. HQ60 supported.

File-level evidence:
- Latest 120fps clip `UITEST_IMG_writer_AE37F9E5-C188-4A19-89D1-E45B1BE995EF.mov`: aprn / AAC / gyrf; 605 video frames, 5.043333 s. 605 native K samples match 605 video frames; no interpolated/fallback K; maximum matching error 0.834 ms; embedded per-frame protobuf K checked against the captured values with `tools/validate_intrinsics.py` (PASS). IMU measured pre/post coverage 99/187 ms; maximum gyro/accel sample gap 9.964 ms. Native IMU remains about 100Hz, not a claim of 120Hz physical IMU sampling.
- Latest 120fps clip also completed full video/audio decode with ffmpeg (exit 0, empty error log); evidence: `preview120-decode.log`.
- Earlier Sony 120fps clip `...3367E642-2849-4B95-B560-BEA6456E69A2.mov`: 602 frames / rtmd, K validator PASS (max alignment 0.840ms), complete video/audio decode passed. Its audio was LPCM before the AAC change.
- Earlier AAC+Proto 120fps clip `...9AC96944-4F83-42AE-ADA1-88FE114378D8.mov`: K validator PASS, contained one capture-side FrameWasLate event in the middle of recording; retain this negative evidence rather than claim all trials were lossless.
- Both 0-degree and portrait 90-degree configurations passed the app's MOV rotation check. Orientation overrides were used by the automated harness; physical gravity turning and Gyroflow stabilized export remain separate manual acceptance work.

Evidence is in `artifacts/prostorage-20261016/full-chain/`; MOVs and original diagnostic data remain on the device and selected copies in `/tmp`. No user media deleted, no commit/push. Debug and Release compile checks passed. These are short functional tests, not thermal/long-duration reliability acceptance. Optical IMU synchronization, AF near/far at high fps, background recovery, all lenses and SSD Writer behavior remain unverified. H.265 and SSD continue their existing MovieFileOutput routes.


### Open Gate dedicated-storage Writer regression (2026-10-16)

Device: iPhone 18 Pro Max / iOS 27.0.1. Added DEBUG automation flag `--writer-opengate`; capture implementation unchanged. Actual format 71: 4224×3024, aprn/aprh, maximum 60fps. No Open Gate 120fps advertised.

| Codec / FPS | Output | Frames (~10 seconds) | Capture drops | Result |
| --- | --- | --- | --- | --- |
| RAW / 30 | Sony MOV, portrait transform | 302 | 0 | Finalized; full video/audio decode and K validation PASS |
| RAW HQ / 30 | GyroflowProto, landscape | 303 | 0 | Finalized; full video/audio decode and K validation PASS |
| RAW / 60 | Sony MOV, portrait transform | 604 | 0 | Finalized; device K health reports 604 received, 0 failed; MOV not copied for offline decode |
| RAW HQ / 60 | GyroflowProto, landscape | 604 | 0 | Finalized; full video/audio decode PASS (ffmpeg exit 0); native K / embedded protobuf validation PASS (max alignment 0.335ms) |

Encoder preparation reported 1/1/3/3 late frames before movie start, separately excluded from capture drops. Peak writer queue depth 1. HQ60 MOV indexed video duration 10.066667s, aprh video + AAC audio + 604 gyrf packets. RAW30 Sony K maximum alignment 0.851ms; HQ30 protobuf K 0.851ms. No K fallback used by these successful native-metadata checks. Final screenshot shows 4224×3024/60fps, green PVS/IMU, normal preview and no alert.

Evidence: `artifacts/prostorage-20261016/opengate/`. Original MOVs remain on phone. Short functional tests only: long recording, optical sync/stabilized export, AF near/far and gravity-driven physical rotation remain unverified. No commit/push.


### Naming, white balance presets and storage safety (2026-10-16)
- Manual RAW Writer recordings now share the existing collision-safe IMG_####.mov allocator. Explicit automated captures keep UITEST_ names. Real test wrote IMG_0003.mov (152 frames, IMU finalized).
- WB menu: Daylight 5600K, Shade 7000K, Cloudy 6500K, Tungsten 3200K, Fluorescent 4000K, Flash 5500K. All use manual temperature, tint 0, clamped device gains; approximate presets, not measured illuminant calibration. Menu compiled; physical UI selection for all six not yet exercised.
- HUD displays free destination bytes and conservative estimated minutes, refreshed every 2 seconds. Format/FPS-dependent budget uses 8 bits/pixel for HQ, 6 RAW, 0.5 other, plus audio/metadata allowance; actual variable bitrate can differ. This is not a guaranteed recording duration.
- Reserve max(1GB, 5 seconds estimated bitrate), require 10 additional seconds before start, plus ordinary local space for logs. MovieFileOutput has minFreeDiskSpaceLimit; both capture routes monitor storage and stop once below reserve. No intentionally filling the device.
- Injected DEBUG low-space startup rejected recording. Injected low space after start stopped at 125 frames, zero capture drops, successful IMU finalization. Test harness delayed stop now cannot restart an already completed recording.
- In-place installation validation: all 13 pre-existing Media files remained with identical names/sizes (not a full content-hash comparison). Production bundle ID unchanged. No evidence that this update deleted media; uninstall/reinstall is not a preservation workflow.
- User-authorized cleanup removed 12 UITEST_ movies (13,548,993,370 bytes) and matching sidecars; preserved IMG_0001, IMG_0002, IMG_0003. Explicit DEBUG cleanup flag only; never automatic on ordinary update/start. Replenished system Pro Video Storage successfully to 150,000,001,024 bytes, then relaunched without cleanup/test flags.
- Debug and Release build succeeded. SSD capacity behavior and actual physical disk exhaustion remain untested.

- Final ordinary-launch screenshot exposed a RAW WB-ready timeout at default 0.5x; this remains unresolved and is not a passing all-lens test. Restored active session to tested 1x Open Gate and recorded IMG_0004.mov: 152 frames, zero recording drops, audio/IMU finalized. This short verification clip was created after cleanup; user IMG_0001–0004 remain. Do not claim next ordinary 0.5x launch is fixed.


### HUD, 10-frame buffering and ultra-wide WB recovery (2026-10-16)
- Free GB / estimated time moved directly below timecode row, above video specification. Final device screenshot verified.
- User deferred uninstall-persistent storage; no copies, cloud destinations, or bundle-ID changes added. Continue in-place upgrades with Media untouched.
- RAW Writer pending-video queue limit 10. Injected blocked video input reached exactly 10 queued frames; the next incoming frame triggered `raw_writer_buffer_overflow`. Preserved partial 5-frame MOV, reported encoding/storage throughput error; not accepted as a complete recording. Clarifies backlog does not uniquely diagnose a disk fault. Fixed matching `.mov.pending-imu.json` sidecar deletion when deleting a recording.
- Prior 0.5x failure log had 447 video / 650 audio packets but no lock completion. Preview now retries the lock at 12-frame intervals, at most 3 attempts, using explicit current gains after first sentinel request. Readiness still requires an actual system completion; no timeout-based success. Exhausted timeout detaches failed preview so a subsequent REC can prepare again. This exhaustion-retry branch was not separately fault-injected.
- Forced first-completion loss: attempt 2 returned effective time, ultra-wide RAW 30fps captured 152 frames with AAC/IMU finalization, zero recording drops. Lens switches during the same run also recovered through attempt 2.
- Three subsequent ordinary launches (no injected failure): all ready. Attempts 2, 1, 3 respectively; actual intermittent missing callback recovered. Final screenshot 0.5x RAW 4224×3024/60, locked WB, no alert. This establishes bounded recovery evidence, not elimination of the OS callback defect or long-run guarantees.
- Deleted the two scoped fault-test clips and their sidecars after saving logs. IMG_0001–0004 retained; replenished PVS to 150GB. Final launch has no fault/cleanup arguments. Debug build PASS; diff check PASS.
Evidence: `artifacts/prostorage-20261016/wb-buffer/`.

### 2026-10-16 WB/readiness and responsiveness follow-up

The RAW experiment now supports a separately logged stable locked-gain readback when three WB completion requests do not return: eight live frames with matching current in-use gains, locked/non-adjusting state, and increasing PTS. The exact completion timestamp is not fabricated. Failure invalidates the preview for the next attempt. See `RAW_HQ_THREAD_REVIEW_2026-10-16.md` for the HQ matrix, fault injection, queue changes and remaining isolated capture drop risk. This remains a DEBUG experiment.

## Release promotion — 2026-10-17, 1.0 (20261017.1)

Dedicated-storage RAW/RAW HQ now selects AVAssetWriter on iOS 27+ in both Debug and Release, without an opt-in user default. H265 and external-SSD recording retain MovieFileOutput. Test auto-recording, naming, forced orientation, buffer blocking and dropped-WB-completion injection remain DEBUG-only. Older iOS versions keep availability guards and cannot enter this path.

Release build and archive passed; App Store Connect upload succeeded on October 17 at 00:32 CST. The binary keeps the existing bundle ID and version 1.0, build 20261017.1. Export compliance key remains false. No App Store public-release submission was made.

The earlier Debug recordings establish RAW capture/IMU/K and Gyroflow import evidence (including IMG_0008, 36,828,613,621 bytes, approximately 103 seconds). They are not a Release device regression. Release UI test compilation initially required ENABLE_TESTABILITY=YES; the subsequent runner exited with code 74 before connecting. The user then removed the phone and device tests were stopped. Release recording remains pending physical verification.

Added testReleaseDedicatedRAWRecording for the next connected-device regression. No automatic raw experiment flags are passed by that test. Known risks: intermittent 0.5x Open Gate HQ60 capture drops; camera/codec/FPS support differs by device; no promise of 120fps across lenses.
