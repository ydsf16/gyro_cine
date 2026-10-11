# Recording/UI orientation audit — 2026-10-11

## Contract and findings
- All selectable rear physical lenses feed one CaptureCoordinator. HEVC, RAW and RAW HQ all use the same AVAssetWriterInput transform assignment. File/SSD placement does not select a different orientation path.
- Video direction is frozen when REC is accepted, before IMU pre-roll. UI orientation never supplies its value. Further physical rotations do not change that clip's transform.
- Defect repaired: old gravity callback refreshed its timestamp even when a flat/ambiguous pose could not produce a direction. A previous orientation could therefore appear fresh indefinitely. REC now reads the current CoreMotion fused sample directly, accepts age 0…0.5s, and rejects flat or near-diagonal readings rather than reusing an old direction.
- UI and preview use UIWindowScene.interfaceOrientation; no forced scene geometry or device-orientation override is used. Preview now handles upside-down explicitly and preserves its existing angle when the scene orientation is unknown.
- Disable automatic mirroring and require native unrotated, unmirrored capture at start. Every recorded frame must preserve that state and the selected sensor-buffer dimensions.
- Output verification previously checked angle only. It now checks the complete six-component MOV transform against the actual encoded dimensions, including positive-bound translation and absence of mirroring.
- Freeze the gravity vector/timestamp in diagnostics to distinguish direction classification from container/player problems.
- GCSV does not override MOV rotation. Sony transport preserves the video track. Protobuf carries the same rotation in its clip header. All retain sensor-native IMU axes, avoiding a second IMU rotation for portrait presentation.

## Verification
- Simulator: 41 tests passed, zero failures (`/tmp/gyro-direction-tests.log`).
- Gravity tests cover cardinal poses, flat/diagonal poses, stale/future timestamps, and portrait UI with a landscape recording direction.
- Matrix tests cover six sensor sizes × four directions and reject bad translation/mirroring.
- AVAssetWriter passthrough test writes four actual MOV transforms, appends both rtmd/gyrf tracks and reads back transforms and frame counts. This verifies the container path; it does not exercise HEVC/RAW/HQ encoders or physical sensors.
- Previously recorded clips do not contain REC gravity snapshots, so code inspection cannot retroactively establish how they were held.

## Device acceptance still required
For each supported physical lens (0.5x, 1x, telephoto) × codec (HEVC/RAW/RAW HQ), exercise portrait, both landscapes and upside-down, with portrait lock on/off. RAW/HQ require SSD. Use an upright text target to independently assess actual image orientation, not just transform metadata. Rotate after REC and confirm the stored transform remains fixed. Verify Files/player and Gyroflow separately. Unsupported combinations are N/A, not passes. No blanket hardware guarantee is claimed.
