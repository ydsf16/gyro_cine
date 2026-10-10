> Updated device results: [iPhone 16 lens acceptance](PHYSICAL_LENS_DEVICE_REPORT.md). Earlier pending/offline statements below describe the previous stage.

# Lens selection acceptance — 2026-10-10

## Behavior

- Detect physical rear ultrawide, wide and telephoto cameras with AVCaptureDevice.DiscoverySession.
- Display magnification using system virtual-device switch-over factors normalized to the wide camera. For example [2, 6] produces 0.5x / 1x / 3x, and [2, 10] produces 0.5x / 1x / 5x. Missing ratio metadata falls back to the lens name, never a guessed multiplier.
- Show detected lenses; disable those without a 3840x2160 / 30 fps format. HEVC writer capability is checked when recording starts.
- Selection reconfigures the physical camera and preview; each selected physical device remains at videoZoomFactor=1. UI magnification is relative to the main camera, not digital zoom on that physical device.
- Lock lens selection immediately when recording is requested, during capture and finalization. Disable recording while camera configuration is pending.
- Diagnostics store lens ID, type, name, multiplier and format capability. GCSV/profile identify the selected lens. Profile K is generated from that recording's measured API data.
- Digital crop presets such as a main-camera 2x crop are not advertised as additional physical lenses.

API references: [Apple physical telephoto discovery](https://developer.apple.com/documentation/avfoundation/avcapturedevice/devicetype-swift.struct/builtintelephotocamera), [switch factors](https://developer.apple.com/documentation/avfoundation/avcapturedevice/virtualdeviceswitchovervideozoomfactors). Xcode SDK AVCaptureDevice.h documents constituent ordering and switch-factor mapping.

## Verification

PASS: 8/8 unit tests and 1/1 navigation UI test. Final simulator log: `artifacts/test_logs/lens_selection_final_tests.log`.
PASS: final signed iOS build: `artifacts/test_logs/lens_selection_final_device_build.log`.
Tests cover 3x/5x/dual-camera ratios, invalid factors, selection locking, and selected-lens profile/GCSV metadata in addition to existing clock/unit/export checks.

## Device checks pending

`devicectl list devices` currently reports iPhone 16 unavailable. No new device discovery, optical switching, per-lens K availability or recording is marked PASS. Simulator has no physical camera and cannot validate those behaviors.

1. Connect/unlock phone and install the build. Check buttons match discovered hardware (ultrawide/main/telephoto if present). Unsupported 4K30 lenses must be disabled.
2. Switch each enabled lens before recording; verify preview field of view changes and highlighted selection/settings agree.
3. Record 20 seconds on each selected lens in a bright textured scene. During recording, lens buttons must be disabled.
4. Export four files to a separate folder for each recording. Compare lens_profile.json camera_setting and K against diagnostics.selectedLens and video_samples.jsonl.
5. Open each project in stable Gyroflow 1.6.3; confirm video/gyro/profile load, then synchronize individually. Static profiles still need lens-specific distortion calibration and per-lens IMU-axis/quality acceptance.

Expected application start log includes `lens=... multiplier=... cameraID=...`; completion includes frame and IMU counts. Failed/missing API K retains raw recording for diagnosis. M1 remains unaccepted pending device/calibration work.
