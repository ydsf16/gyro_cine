# Calibration pending

No lens profile, K, distortion, rolling-shutter readout, OIS state or IMU-to-camera rotation is embedded. `preferredVideoStabilizationMode = .off` disables the configurable electronic mode where supported; it does not prove physical OIS or sensor shift is off.

For iPhone 16 M1: record a static scene, known positive/negative rotations around each device axis, a textured rapid-motion scene for Gyroflow sync, and a lens-grid capture at the exact 4K30 output mode. Archive the original MOV/JSONL/raw IMU and calibration results with device model, iOS build and lens format.
