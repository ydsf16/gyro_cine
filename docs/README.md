最新自动曝光上限与同步补偿：[EXPOSURE_COMPENSATION_REPORT.md](EXPOSURE_COMPENSATION_REPORT.md)

> Latest correction: [clock origins, RoamShot comparison and cropping](TIMING_AND_CROP_REPORT.md). GCSV projects now restore the first-sample origin; earlier empty-offset statements describe the previous implementation.

> Latest connected-device run: [physical lens report](PHYSICAL_LENS_DEVICE_REPORT.md). Capture and four-item share UI passed; main offline sync and calibration remain unresolved.

> Current M1 scope (2026-10-10): selectable physical lens (fixed during each clip), Gyroflow 1.6.3, MOV + GCSV + lens_profile.json + clip.gyroflow. Native JSONL is deferred. See [lens selection](LENS_SELECTION_REPORT.md). See [fixed-lens export report](LEGACY_EXPORT_REPORT.md); earlier sections below are historical.

# RawMotion Recorder (M1 implementation candidate)

New SwiftUI iOS 18.2+ app for fixed back wide-camera HEVC 4K30 video, AAC audio, and separate raw CoreMotion gyro/accelerometer capture. ProRes RAW work is locked until M1 device and Gyroflow acceptance passes.

## Build

```sh
cd /Users/grape/project/raw_motion_recorder
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project RawMotionRecorder.xcodeproj -scheme RawMotionRecorder -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Open the Xcode project, set a personal development team and unique bundle ID, then run on iPhone 16 with iOS 18.2+. Camera/microphone prompts appear on first launch. `Documents/recording_*` retains a failed attempt for inspection; only a successful finalization creates `clip.jsonl`. `diagnostics.json` records status and error. The app never silently switches from 4K30 to another resolution.

The app uses `AVCaptureVideoDataOutput` and `AVAssetWriter` to retain source video PTS. The MOV is re-read after finalization to count encoded frames. See `TIME_CONVENTIONS.md` for the remaining timing limits. The iOS JSON writer is checked by the pinned protobuf descriptor in `tools/validate_recording.py`; no guessed lens or readout metadata is written.
# 最新真机快门与文件夹验收：[SHUTTER_FOLDER_DEVICE_REPORT.md](SHUTTER_FOLDER_DEVICE_REPORT.md)

