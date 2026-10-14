# GyroCine

Current iOS camera app, promoted from the RAWFocusTest-based rebuild.

- Xcode project: `gyro_cine.xcodeproj`, scheme: `GyroCine`.
- Regenerate with `xcodegen generate` from `project.yml`.
- iOS 18.2+, bundle ID `com.tinygrape.RawMotionRecorder`, version 1.0 (1).
- Sources: `Sources/`; app icon/localization: `Resources/`; tests: `Tests/` and `UITests/`.

## Capture defaults

First launch after migration resets capture preferences to H.265, nearest supported 4K/30 fps,
internal storage, Sony MOV and Debug off. Existing recordings are preserved.
Camera specifications continue to persist after that one-time reset.
Changing codec, resolution, frame rate or physical lens restores A-Max (maximum exposure
1/(4×fps), clamped to device limits), auto ISO/white balance and continuous autofocus.

Recording direction comes from fused gravity at REC. It is frozen for that clip. When the
phone lies flat, retain the last unambiguous direction; on a flat cold launch, use portrait.
Video uses MovieFileOutput. VideoDataOutput supplies native-raster intrinsics; it does not
encode video. MOV display rotation and telemetry profile output dimensions reflect gravity.

## Output and verification

Sony RTMD or Gyroflow Protobuf are embedded into a single MOV without re-encoding video.
Debug retains raw IMU and camera-frame JSONL. `tools/validate_intrinsics.py` checks MOV
intrinsics against these retained samples and capture logs. Short recordings and lens
switches can be exercised with XCUITest; physical motion/focus and RAW require hardware.
External SSD capture is not connected in this rebuild yet.
Exposure/IMU timing compensation remains unchanged and is not optically calibrated.

## Previous implementation

Historical reports in `docs/` refer to the previous capture pipeline unless stated otherwise.
Preserved branches:
- `codex/backup-original-before-rebuild-20261014`
- `codex/backup-rebuild-before-promotion-20261014`
