# TestFlight feedback triage · 2026-10-15

Baseline: `80417ff` (`baseline/gyrocine-20261015.1`). Build 1.0 (20261015.1) is the existing TestFlight build; the changes below have not been distributed through TestFlight.

| Feedback | Current disposition |
| --- | --- |
| >30 fps MOV unrecognized or unplayable | Needs the original MOV, exact codec/raster/FPS, device/iOS, player, and same-session Log. Do not infer an IMU-frequency limit from video FPS. Inspect video/audio tracks and PTS before changing capture settings. |
| Stabilization field of view suddenly expands after shake | Needs original MOV plus Gyroflow version, lens profile, sync/zoom settings and a reproducible timestamp. No blind telemetry transform change. |
| Launch defaults to 0.5× | Intentional per the existing product request; already in the baseline. |
| ProRes RAW 4K/120 fails IMU, then UI sticks until restart | A concrete missing-recovery-job path now stops recording, releases finalizing state, and reports an error. Hardware reproduction is still needed to identify the actual 120 fps failure. Check MOV cadence, dropped K callbacks, raw IMU gaps, storage, and finalization stage. |
| Quick video specs on camera screen | Existing Settings menus support codec/raster/FPS. Moving specs to the HUD conflicts with the current low-frequency settings design; defer UI change until the owner chooses a compact interaction. |
| LUT import / baked LUT for H.265 or H.264 | New color pipeline and export behavior; defer until capture/playback reliability is established. H.264 recording is not an existing format. |
| Flash crashes | Safe white-balance readout is in the baseline. Compare only symbolicated crashes from the new build; old reports alone cannot establish a separate playback defect. |
| 180° shutter angle follows FPS | Added as an explicit Shutter mode. Default A-Max 1/200 s remains. Angle mode is manual exposure with current ISO. |
| Save exposure compensation / white-balance profile | Requires an agreed metadata format and downstream reader validation; leave current capture metadata unchanged. |
| A/B focus presets | Deferred UX feature. |
| Lower shutter angles | Angle ruler includes values down to the camera's supported minimum. Smaller angle gives faster shutter and less motion blur. |

## Checks

- Generic iOS Debug build passed after the baseline.
- `DefaultsAndOrientationTests` passed on iOS 26.3.1 Simulator, including angle-to-exposure calculations.
- The new shutter-angle XCUITest compiled for iPhone 16, but Xcode could not launch it because the device was locked. No on-device result was inferred.
- Physical RAW/120, playback, stabilization and on-device angle behavior remain unverified for this change.
