> Updated device results: [iPhone 16 lens acceptance](PHYSICAL_LENS_DEVICE_REPORT.md). Earlier pending/offline statements below describe the previous stage.

# Fixed 1x / Gyroflow 1.6.3 acceptance — 2026-10-10

This user-approved scope supersedes the default JSONL export requirement for M1.

## Implemented

- Independent back wide-angle camera, explicitly `videoZoomFactor = 1`; no zoom or lens-switch controls. Autofocus is unchanged; fixed zoom does not guarantee zero lens breathing.
- Finalizer writes `clip.mov`, `clip.gcsv`, `lens_profile.json`, `clip.gyroflow`. Library shares these four files together. Raw gyro/accel, per-frame API K and diagnostics remain in the recording folder. New recordings no longer produce the known-broken native `clip.jsonl`.
- GCSV 1.3 contains each actual gyro sample exactly once, seconds and rad/s, with source-to-asset clock mapping. Accelerometer stays in raw evidence; no unverified accel resampling/sign conversion is introduced. Horizon lock is not accepted.
- Lens profile uses median output-coordinate API K and explicitly uncalibrated zero distortion. All frames must have valid K or finalization fails while retaining raw files. This is a provisional lens profile, not a completed calibration.
- Project embeds the profile, references video/GCSV with file URLs, starts with empty offsets and requires offline synchronization. Rolling shutter correction is disabled, hardware readout remains unknown.
- Gyroflow 1.6.3 rejects plain relative paths; it accepts file URLs and falls back to same-folder basenames when original files are missing. Keep all four files in one folder.

## Verification

- Production Swift exporter run on existing device recording `recording_20261010_195957`: 674 frames, 2258 original gyro samples. This is replay of earlier capture, not a new device recording.
- Stable `/Applications/Gyroflow.app` 1.6.3 imported the generated project after moving its folder: 2258 samples, `has_accurate_timestamps=false`, no per-frame time offsets. Log: `artifacts/test_logs/legacy_stable_relocated.log`.
- Stable project re-export loaded the embedded K (fx 2765.15979 px) and retained empty sync offsets. Artifact: `artifacts/device_runs/roamshot_ui20/legacy_stable_project/checked.gyroflow`. CLI export required an explicit desktop output folder in the test project. The initial attempt failed; successful retry log: `artifacts/test_logs/legacy_stable_project_retry.log`. Bookmark warning persists; a saved project is verified, GUI bookmark behavior is not.
- IMU duration warning is retained: 22.640 s versus video 22.465 s; raw pre/post video sensor samples were preserved. This is not a synchronization accuracy pass.
- Signed generic iOS build: PASS, `artifacts/test_logs/legacy_device_build.log`.
- Simulator: 6/6 unit tests + 1/1 navigation UI test PASS. Final log `artifacts/test_logs/legacy_export_final_simulator.log`.

## Device acceptance still pending

Tool reports iPhone 16 unavailable. New app install, fixed-zoom capture, share-sheet delivery, and stabilization quality are NOT marked passed. M1 remains incomplete; RAW has not started.

1. Connect/unlock iPhone; install latest build. Settings should show fixed main 1x and Gyroflow 1.6.3 export.
2. Aim at a bright textured scene, record 20 seconds while slowly rotating horizontally/vertically; stop and wait for Completed.
3. Share all four files to the same Mac folder. Confirm raw IMU and video_samples remain in the app container.
4. Open `clip.gyroflow` in stable 1.6.3. Confirm video, gyro graph and the profile marked UNCALIBRATED. Run offline synchronization at several points; inspect offsets and save project.
5. Export a stabilized video and compare against the original. Do not copy another clip's offsets. Complete lens calibration and axis validation before accepting quality.

Logs expected: app `completed actualFrames=... imuEvents=...`; Gyroflow source `gcsv RawMotionRecorder`; no unexpected per-frame offsets before synchronization. API K variation from focus/OIS is still a measured limitation of the static model.
