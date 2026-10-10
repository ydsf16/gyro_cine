# Metadata, RoamShot clock comparison and cropping — 2026-10-10

> Update: the clock-fit residual gate is now 2 ms. See [MOV timebase validation](CLOCK_FIT_GATE_REPORT.md). The 1 ms figure below records the earlier implementation.

## Confirmed findings

1. RoamShot `App/Capture/RecordingWriter.swift` converts each sample PTS from `AVCaptureSession.synchronizationClock` to `CMClockGetHostTimeClock()` with CMSyncConvertTime. `Sources/CaptureCore/StabilizationInput.swift` fits paired frame host/video times with a centered affine clock map. `Engine/src/lib.rs` feeds IMU directly to Gyroflow with has_accurate_timestamps=true. It bypasses GCSV normalization. These source facts do not prove hardware exposure/IMU synchronization accuracy.
2. RawMotion previously assumed identical capture/host clocks. New device measurement found a 0.554 ms conversion, and another 0.633 ms; neither explains approximately 50 ms by itself. The frame callback delay is delivery latency and must not be applied as synchronization correction.
3. Gyroflow stable 1.6.3 normalizes GCSV samples by subtracting the first gyro timestamp. Actual parsed metadata confirms the first sample becomes zero. For `recording_20261010_205636`, the original first gyro time was +34.946520 ms. Previous exports preserved this in GCSV but provided no project compensation, so stable import lost it.
4. On that same ultra clip, prior offline offsets 40.99–46.73 ms include the missing 34.95 ms origin. The remaining approximately 6–12 ms are optical-fit residuals, not a measured hardware latency. User screenshot offsets vary more widely (including 67.17 ms). Do not claim a universal 50 ms compensation or guaranteed synchronization.

## Implemented

- Per-frame source PTS and converted host PTS saved separately. Missing/invalid conversion fails instead of silently assuming an epoch.
- Fit host times to actual encoded MOV frame PTS. Store origin, slope, intercept and maximum residual; reject invalid monotonicity, rate beyond 1000 ppm or residual above 1 ms. Map original gyro sample times through this fit, leaving raw records unchanged.
- Project `offsets["0"]` restores the first mapped gyro time discarded by GCSV; rough sync offset uses the same per-clip value. This is deterministic clock-origin compensation, not a physical sync estimate. AutoSync results are total offsets, not extra offsets to add on top.
- New metadata: specific hardware model (iPhone 16 / iPhone17,3), lens identity, API parameter source and date; MOV make/model/software/creationdate. Unknown distortion, measured focal length and calibrator identity are not fabricated. `calibrated_by` explicitly says API estimate/not calibrated.
- Default project explicitly sets dynamic zoom window 4 s, FOV 1.0, no zoom cap. This is postprocessing crop; capture remains fixed on the chosen physical lens. The screenshot's No zooming mode exposes uncovered frame boundaries. Official guidance: https://github.com/gyroflow/docs.gyroflow.xyz/blob/main/getting-started/basic-usage/stabilization.md

## Review package

`artifacts/device_runs/physical_lenses/ultrawide_review/` contains copied original MOV/GCSV, completed lens profile and `clip.gyroflow` with previously estimated per-clip AutoSync offsets retained plus dynamic crop. Existing original and user projects were not overwritten. Old recordings lack converted clock evidence, so no new hardware conversion was invented for them.

`stabilized_dynamic.mp4`: Gyroflow 1.6.3 render, H.264 1920x1080 + AAC48k, 674 decoded frames. Corner-patch check on all frames found zero near-black corners (threshold mean<2); inspected the frame near the user's screenshot time (6.7 s). This is not a mathematical guarantee for every edge pixel or all future recordings.

## Evidence

- `artifacts/test_logs/gcsv_origin_final_device.log`: 9 unit tests + short device recording passed before the final clock-fit addition.
- `artifacts/device_runs/clock_origin_final/stable_timeline_validation.json`: actual stable reader, 760 gyro samples; +13.617750 ms origin restored, maximum mapped-reader residual 0.000459 ms. MOV metadata independently confirmed by ffprobe.
- Final clock-fit build/device: 10/10 unit tests and short device recording PASS. Recording 20261010_213923 passes raw/GCSV/frame checks; clock fit slope 1.000131066, max residual 0.014757 ms, per-clip GCSV origin 19.692405 ms. Evidence: `artifacts/device_runs/clock_fit_final/`. Log: `artifacts/test_logs/roamshot_clock_final_device.log`.
- `artifacts/test_logs/review_dynamic_render.log` and `ultrawide_review/border_check.json`: crop/render checks.

Remaining acceptance: new textured motion recording to measure optical residual after full clock changes; lens-specific distortion/axis calibration. Small arithmetic/reader residuals do not prove optical synchronization. M1 remains incomplete; RAW not started.
