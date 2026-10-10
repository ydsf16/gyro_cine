# Gyroflow desktop acceptance steps

1. Export the entire `recording_*` folder from Files > On My iPhone > RawMotionRecorder, or use the app's share control. Keep `clip.mov` and `clip.jsonl` together.
2. Run `.venv/bin/python tools/validate_recording.py /path/to/recording_* --report /path/to/validation.json` on macOS. Save stdout and report.
3. Record Gyroflow version/platform. Open `clip.mov`; observe whether `clip.jsonl` loads automatically. If not, manually load `clip.jsonl` as motion data and save the Gyroflow log.
4. Inspect motion graphs, perform auto sync on the rapid-motion clip, apply a compatible measured lens profile, export a stabilized video, and retain input/output comparison and sync offset.
5. Do static, slow horizontal/vertical rotation, and hand-held walking clips. Use 20-second motion captures per the user’s updated scope; a 60-second baseline has already been captured.

Observed: Gyroflow 1.6.3 opens HEVC but rejects manual JSONL import with Unsupported file format. Official parser round-trip succeeds, but missing hardware frame timestamps have unresolved playback-time semantics. See M1_REPORT.md.

Official nightly 1.6.3 (gh2733) auto-loads JSONL and displays motion. CLI `--export-project 2` and `--export-metadata 2:<path>` succeeded. Parsed metadata confirms `has_accurate_timestamps=true` with incorrect descending per-frame offsets; synchronization and stabilization remain FAIL/PENDING. See archived metadata and logs in M1_REPORT.md.

A separate raw-gyro GCSV/offline-sync workflow has now exported a 674-frame 4K stabilization candidate. This does not fix native JSONL readout semantics. Measured offsets, image comparison, calibration assumptions and reproducible steps are in ISSUE_RESOLUTION.md.
