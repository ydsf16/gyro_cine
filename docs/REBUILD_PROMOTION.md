# Rebuild promotion — 2026-10-14

The RAWFocusTest-derived app is now the root GyroCine project. The previous app and
pre-promotion rebuild are preserved on the two backup branches listed in README.md.

Changes:
- Restore original GyroCine icon, display name and bundle identifier; version 1.0 (1).
- Freeze recording direction from fused CoreMotion gravity at REC, retaining last
  unambiguous direction when flat. A flat cold start defaults to portrait.
- Write matching MOV display rotation, Proto rotation and profile output dimensions;
  preserve sensor-native K/IMU coordinates and compressed video payloads.
- One-time settings migration; reset A-Max to 1/(4×fps), auto exposure/WB and AF-C
  whenever video specifications or the physical lens change.
- Exposure/IMU timestamp compensation is unchanged.

Validation:
- iOS device build succeeds; original bundle installed and app starts on iPhone 16.
- Three simulator unit tests pass: four gravity directions/fallback, exposure bounds
  over 24–120 fps, and one-time settings migration.
- Device startup log verifies H.265 3840×2160/30 and maximum exposure 1/120.
- After USB reconnect, all four iPhone 16 XCUITests pass: frame-rate changes restore
  A-Max, Sony recording, Proto recording, and recording after physical-lens switching.
- All three recorded MOVs pass the independent K/IMU container validator. Actual
  gravity at REC includes both portrait and landscape; MOV rotation is respectively
  -90 degrees (ffprobe convention) and identity, matching the selected directions.
- RAW physical autofocus and the two remaining physical orientations still require
  device acceptance; no optical IMU timing calibration is claimed.
