# Gyroflow desktop acceptance steps

1. Export the entire `recording_*` folder from Files > On My iPhone > RawMotionRecorder, or use the app's share control. Keep `clip.mov` and `clip.jsonl` together.
2. Run `.venv/bin/python tools/validate_recording.py /path/to/recording_* --report /path/to/validation.json` on macOS. Save stdout and report.
3. Record Gyroflow version/platform. Open `clip.mov`; observe whether `clip.jsonl` loads automatically. If not, manually load `clip.jsonl` as motion data and save the Gyroflow log.
4. Inspect motion graphs, perform auto sync on the rapid-motion clip, apply a compatible measured lens profile, export a stabilized video, and retain input/output comparison and sync offset.
5. Do static, slow horizontal/vertical rotation, and hand-held walking clips. Repeat the 60 s, 3 min, and 5 min duration checks.

No desktop Gyroflow result has been observed for this project yet.
