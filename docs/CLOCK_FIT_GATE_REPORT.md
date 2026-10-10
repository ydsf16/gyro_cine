# MOV clock-fit gate correction — 2026-10-10

## Cause

The iPhone 16 recording `recording_20261010_215207` retained 270 video frames and 1825 raw motion events but failed finalization at the self-imposed 1 ms affine clock-fit residual gate. Its HEVC MOV video track has a 1/600-second time base. Of 269 frame intervals, 268 are 20 ticks and one is 21 ticks, at frame 268 (one-based). The encoded time of that frame and the following two frames is one tick, or 1.667 ms, later than the uniform 30 fps grid.

Recomputed from the saved `video_samples.jsonl` and the actual MOV packet PTS: fit slope 0.9999597543 (−40.25 ppm), maximum fit residual 1.59514 ms, maximum source-to-MOV timestamp residual 0.83186 ms. Frame count, source-to-MOV 1 ms gate and 30 fps interval ±5 ms gate pass. The failed fit was caused by the one-tick MOV PTS step, not missing video or IMU data. This does not validate physical exposure-to-gyro alignment.

## Change and checks

- Affine fit gate raised to 2 ms, allowing one 1/600-second tick plus rounding margin. The 1000 ppm rate gate, strict monotonicity, source-to-MOV 1 ms check and per-frame interval ±5 ms check remain.
- Regression test reproduces a 270-frame clip with a one-tick step across the last three frames; it passes. A two-tick step in the same position is rejected.
- `artifacts/test_logs/clock_tolerance_device.log`: Xcode device test passed, 11 unit tests and one short recording UI test, all zero failures.
- Independent audit of the original 270-frame MOV confirms its saved evidence passes the revised 2 ms fit gate and the other two timing gates.
- Recovered copies of `clip.mov`, `clip.gcsv`, `lens_profile.json`, and `clip.gyroflow` are in `/Users/grape/Downloads/recording_20261010_215207_recovered/`; raw evidence is copied there too. The original failed folder is untouched. Its diagnostics status is `recovered_offline_unverified`.
- Gyroflow 1.6.3 CLI read the recovered project and parsed all 913 GCSV gyro samples. Independent checks confirm the project references the recovered sibling files, every GCSV row maps to its original raw gyro event, and its 31.339845 ms origin offset matches the first GCSV timestamp. Parser log: `artifacts/test_logs/recovered_215207_gyroflow.log`; parsed metadata: `artifacts/test_logs/recovered_215207_parsed.json`.

## Remaining verification

The new gate is tested on device, but a new 20-second exported recording and optical synchronization check have not yet been run. No 50 ms AutoSync accuracy claim is made. M1 remains incomplete.
