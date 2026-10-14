# Rebuild promotion — 2026-10-14

The RAWFocusTest-derived app is now the root GyroCine project. The previous app and
pre-promotion rebuild are preserved on the two backup branches listed in README.md.

Changes:
- Restore original GyroCine icon, display name and bundle identifier; version 1.0 (1).
- Freeze recording direction from fused CoreMotion gravity at REC, retaining last
  unambiguous direction when flat. A flat cold start defaults to portrait.
- Write matching MOV display rotation, Proto rotation and profile output dimensions;
  preserve sensor-native K/IMU coordinates and compressed video payloads.
- One-time settings migration; reset A-Max to 1/(4×fps), auto exposure/WB and AF-C
  whenever video specifications or the physical lens change.
- Exposure/IMU timestamp compensation is unchanged.

Validation:
- iOS device build succeeds; original bundle installed and app starts on iPhone 16.
- Three simulator unit tests pass: four gravity directions/fallback, exposure bounds
  over 24–120 fps, and one-time settings migration.
- Device startup log verifies H.265 3840×2160/30 and maximum exposure 1/120.
- After USB reconnect, all four iPhone 16 XCUITests pass: frame-rate changes restore
  A-Max, Sony recording, Proto recording, and recording after physical-lens switching.
- All three recorded MOVs pass the independent K/IMU container validator. Actual
  gravity at REC includes both portrait and landscape; MOV rotation is respectively
  -90 degrees (ffprobe convention) and identity, matching the selected directions.
- RAW physical autofocus and the two remaining physical orientations still require
  device acceptance; no optical IMU timing calibration is claimed.

## Portrait Sony MOV follow-up (2026-10-14)

Gyroflow's Sony parser constructs its lens profile while visiting the first
metadata track. It needs to have visited the video track first to know rotation.
The muxer now orders video/audio before GyroCine telemetry, and telemetry before
Apple metadata. Existing media samples and chunk offsets remain unchanged.

Validated on Gyroflow Nightly gh2733: the same portrait Sony sample changed from
3840×2160 default export to 2160×3840 after track reordering alone; all `mdat`
payload hashes were identical. A 270° source rotation is expected for this clip.
Existing clips can be copied and repaired without reencoding:

```sh
python3 tools/repair_mov_track_order.py input.mov repaired.mov
```

Reopen the repaired MOV as a fresh input. Saved Gyroflow projects or preserved
export settings may still override output dimensions; set portrait width/height
explicitly in that case. IMU remains in sensor coordinates, K in native image
coordinates; display rotation is carried in the MOV, not applied twice to axes.

The save notification now has a dedicated row above the controls and hides after
3 seconds. REC outer diameter is 68 pt (previously 78 pt).
Actual Gyroflow export was also verified by ffprobe: 2160×3840 with no rotation
side data. The iPhone build passed; two attempts at the updated Sony UI test
failed before test execution because the runner exited with code 74 while
establishing the IDE connection. Save-message timeout is not yet device-accepted.

## Interrupted recording recovery (2026-10-14)

Device evidence: 11:31:05 returned AVFoundation -11818 with recording-success=true;
11:50:22 then failed during foreground-only MOV inspection with -11847 after
backgrounding. Recording completion now honors the success flag. Durable
`.mov.pending-imu.json` jobs capture the original first-frame host clock, frozen
orientation, output mode and relative source paths as soon as recording starts.
A UIKit background lease covers stopping/flushing. MOV inspection/finalization
is deferred until the application is active and protected data is available.
Activation and cold launch retry retained jobs. Existing muxer journal rollback
and telemetry-track detection make recovery safe across interrupted commits and
prevent duplicate tracks. Raw data remains until job completion; failures retain
both the task and raw files. No fabricated IMU is generated for missing coverage.

Validation: unit tests passed. Replaying the real 11:50:22 failure through the
simulator app's cold-launch recovery produced embedded IMU, and rerunning the
same job left the complete MOV SHA256 unchanged. Original media payload hashes
are unchanged. Recovered copy is in ~/Downloads/GyroCine-Recovered. The earlier
11:31:05 clip fails the required 50 ms IMU coverage check and remains untouched.
The packet-based intrinsics validator does not pass this interrupted clip's
frame-count check (AVAssetReader yielded 204 frames versus ffprobe's 207 packets,
including discard packets); full downstream stabilization acceptance is pending.
Physical-device background/relaunch UI test was blocked by the locked phone;
updated app was installed successfully.

### Physical background recovery acceptance

The iPhone 16 UI test now explicitly activates Settings and confirms the camera
app is in a background state before terminating/relaunching it. Home-button
injection did not reliably background the app on this device. A background lease
is acquired at recording start, and UIApplication plus UIScene deactivation
notifications stop capture early enough to retain the IMU tail. Recovery attempts
are deduplicated per foreground entry and old failures are reported together.

On 2026-10-14 the targeted `testSonyFinalizesAfterBackgroundAndRelaunch` passed
(1 passed, 0 failed), including the 3-second save-notice disappearance. Device
logs confirm the 12:56:06 clip's background stop and successful cold-launch
finalization. ffprobe confirms HEVC video, AAC audio and Sony rtmd telemetry.
This validates switching apps/relaunching; physical side-button lock is not
separately asserted by XCTest. Earlier forcibly terminated test clips lack IMU
coverage and remain retained; no missing samples are fabricated.
