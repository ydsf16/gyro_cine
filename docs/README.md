# RawMotion Recorder (M1 implementation candidate)

New SwiftUI iOS 26 app for fixed back wide-camera HEVC 4K30 video, AAC audio, and separate raw CoreMotion gyro/accelerometer capture. ProRes RAW work is locked until M1 device and Gyroflow acceptance passes.

## Build

```sh
cd /Users/grape/project/raw_motion_recorder
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project RawMotionRecorder.xcodeproj -scheme RawMotionRecorder -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO
```

Open the Xcode project, set a personal development team and unique bundle ID, then run on iPhone 16 with iOS 26. Camera/microphone prompts appear on first launch. `Documents/recording_*` retains a failed attempt for inspection; only a successful finalization creates `clip.jsonl`. `diagnostics.json` records status and error. The app never silently switches from 4K30 to another resolution.

The app uses `AVCaptureVideoDataOutput` and `AVAssetWriter` to retain source video PTS. The MOV is re-read after finalization to count encoded frames. See `TIME_CONVENTIONS.md` for the remaining timing limits. The iOS JSON writer is checked by the pinned protobuf descriptor in `tools/validate_recording.py`; no guessed lens or readout metadata is written.
