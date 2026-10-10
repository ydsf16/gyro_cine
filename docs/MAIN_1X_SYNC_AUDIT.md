# 1× 主摄同步核查 — 2026-10-10

Recording: `recording_20261010_230843` on iPhone 16 (iOS 18.2.1). The user exported the four files to Downloads and opened `clip.gyroflow` with Gyroflow 1.6.3.

## File identity and capture mapping

- `clip.mov` creation time 23:08:43 CST, HEVC 3840×2160, 288 video frames; project declares the same count and the 1× built-in wide-angle camera. The GCSV has 970 gyro rows; the phone diagnostics report 970 gyro and 970 accelerometer events.
- Original phone `diagnostics.json`, `video_samples.jsonl`, and `imu_raw.jsonl` were copied to `artifacts/device_runs/main_230843/`. The current Downloads four files are linked there for validation. `tools/validate_legacy_recording.py` passes the format and clock mapping checks; output is `validation.json`.
- The app's per-frame host-to-MOV affine map has 0.008171 ms maximum fit residual. Source-to-asset timestamp residual is 0.570 ms, below its 1 ms gate. These checks do not measure optical exposure-to-gyro alignment.

## Gyroflow offset interpretation

- First GCSV gyro timestamp is +43.490580 ms in the video timeline. Gyroflow 1.6.3 parses this first sample at 0 ms. The project therefore stores `offsets["0"] = +43.490580 ms`, restoring the lost GCSV origin. Its `sync.initial_offset` carries the same value.
- The screenshot's six displayed sync points are approximately 43.49, 58.57, 50.63, 54.31, 48.16, and 45.12 ms. Relative to the deterministic 43.49 ms origin, the differences are approximately 0, 15.08, 7.14, 10.82, 4.67, and 1.63 ms (median 5.90 ms). Their spread shows that optical synchronization has not converged to one proven constant offset.
- For the prior 0.5× clip, first-sample origin was +34.946520 ms and three optical estimates were 40.99–46.73 ms, leaving about 6–12 ms after origin compensation. The 1× and 0.5× total numbers differ because the first available gyro sample starts at a different time in each recording.
- CLI Gyroflow 1.6.3 parsed all 970 gyro samples from the new `clip.gyroflow`; first parsed timestamp is 0 ms. Output: `artifacts/test_logs/latest_230843_parsed.json`.

Result: format and deterministic clock-origin mapping PASS; physical synchronization and stabilization quality PENDING. Unknown lens distortion, sensor-row timing, motion blur, and optical matching can affect AutoSync. No universal 50 ms correction is justified by this recording. M1 remains incomplete.
