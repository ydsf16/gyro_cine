# M1 acceptance report — 2026-10-10

## Status

**PENDING hardware/Gyroflow acceptance.** Task 1/2 code is an unverified implementation candidate. M1 is not passed. M2/ProRes RAW development has not started.

## Available evidence

- Host Xcode 26.3 (17C529), iOS 26.3 simulator test target. Three XCTest cases passed 19:18 CST; three desktop validator tests passed 19:18 CST on a synthetic HEVC MOV. Generic iOS device build succeeded 19:16 CST with signing disabled.
- No iPhone 16 connected/available at last check; `devicectl list devices` reported iPhone 16 (iPhone17,3) `unavailable`.
- No real `clip.mov`, `clip.jsonl`, Gyroflow import, sync, or stabilized export exists yet.

## Required device run

1. Connect and unlock iPhone 16, trust Mac, enable Developer Mode. In Xcode select the device, set Signing Team and build/run the app. Save Xcode console and `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl list devices` output, including device/system build.
2. Grant Camera, Microphone and Motion permissions. Verify preview, 4K30 capability, audio option and available storage. Record denial and low-space paths separately.
3. Record static 60 s, controlled horizontal/vertical rotations 3 min, and walking 5 min. Observe thermal state, visible errors and interruption behavior. Test background/lock while recording; confirm explicit finalization or failed retained folder.
4. Export each complete folder. Run `tools/validate_recording.py` for each. Archive its JSON report, `ffprobe` stream/frame output, `diagnostics.json`, `events.log`, and raw IMU logs. Check gyro/accel gaps and duplicates. The `events.log` records state transitions, start settings, frame/event counts and errors; Xcode console uses logger subsystem `com.tinygrape.RawMotionRecorder`.
5. Follow `GYROFLOW_VALIDATION.md`; archive Gyroflow version, auto-load result, manual-load result if needed, motion sync estimate, stabilized output, and before/after comparison.

## Acceptance checklist

- [ ] iPhone 16 60 s / 3 min / 5 min captures save and play.
- [ ] Actual HEVC frame count, PTS order and audio track verified.
- [ ] Official protobuf parsing and MOV/JSONL frame correspondence verified on real files.
- [ ] Gyro/accel continuity and sync error measured.
- [ ] Gyroflow auto-load or documented manual-load result.
- [ ] Gyroflow real sync and stabilized export.
- [ ] Permission, space, interruption, background, thermal and lock failures characterized.

## Known limits to resolve

- Video PTS to CoreMotion epoch relation is checked coarsely; exposure readout timing and physical offset require real calibration.
- No lens calibration or OIS correction is available. Gyroflow stabilization quality is unknown.
- Folder sharing and long recording performance require device validation.
