# iPhone 12 capture QA — 2026-10-16

Device: iPhone 12 (`iPhone13,2`), iOS 18.6.1. Debug build, physical capture through `AVCaptureMovieFileOutput`; no video re-encoding. Tests launched through `devicectl`, without iPhone mirroring or an XCUITest runner during cadence capture. Original `IMG_` media was untouched.

## Results

| Case | File | Video | Audio | Frame PTS | Embedded IMU |
| --- | --- | --- | --- | --- | --- |
| HEVC 4K60 | `UITEST_IMG_2026-10-16-00-47-23.mov` | 3840×2160, 20.182 s, 1211 frames, 60.005 fps by first/last PTS | AAC, 20.180 s | Max gap 18.333 ms; 0 gaps >1.5 frame periods | Sony `rtmd` track, 2019 samples |
| HEVC 1080p120 | `UITEST_IMG_2026-10-16-00-45-52.mov` | 1920×1080, 20.093 s, 2410 frames, 119.933 fps by first/last PTS | AAC, 20.093 s | Max gap 8.750 ms; 0 gaps >1.5 frame periods | Unavailable: this camera format does not deliver measured per-frame K; Media must show `!IMU` |
| HEVC 1080p120, K-capable `420f` [33] | `UITEST_IMG_2026-10-16-01-10-23.mov` | 1920×1080, 20.040 s PTS span, 2321 frames, 115.77 fps | AAC, 20.047 s | 85 missing frame periods; max gap 17.083 ms | Sony `rtmd` embedded; 2359 K callbacks, 86 data discontinuities |
| HEVC 1080p120, K-capable `420v` [32] | `UITEST_IMG_2026-10-16-01-12-28.mov` | 1920×1080, 20.115 s PTS span, 2415 frames, 120.010 fps | AAC, 20.122 s | Max gap 8.750 ms; 0 gaps >1.5 frame periods | Sony `rtmd` embedded; 2451 K callbacks, 2 late K callbacks |
| HEVC 1080p240, `420v` [34] | `UITEST_IMG_2026-10-16-01-23-19.mov` | 1920×1080, 10.057 s PTS span, 2410 frames, 239.543 fps | AAC, 10.060 s | Max gap 4.584 ms; 0 gaps >1.5 frame periods | No Sony `rtmd`: format does not provide K; `video_only_completed` logged |

`ffprobe` parsed both files. Full HEVC video decode with `ffmpeg` returned success for both. One `null`-muxer nonmonotonic-DTS warning occurred while decoding the 120 fps clip; the source MOV packet DTS values are strictly increasing and unique. The 120 fps clip is video/audio-valid, but not a Gyroflow-ready single MOV.

The 4K60 capture log reports 1235 K callbacks, no callback failures, no `AVCaptureVideoDataOutput` drops, and a maximum K PTS gap of 16.700 ms. Raw gyro/accelerometer had 2055/2056 samples, ~9.97 ms median and maximum sample gap, with 80/88 ms before the first movie frame and >290 ms after its end. IMU packaging completed in 0.534 s. These measurements support the shared clock and interpolation path for this clip; they do not establish optical synchronization or stabilization quality under motion.

The iPhone 12 ultra-wide camera has four 1920×1080 high-rate format variants. Formats [32]/[33] provide measured K but crop the field of view to ~68.5°; [34]/[35] keep ~107.5° but do not provide K. Format [33] dropped ~3.5% of video frames in the controlled 20-second run. Format [32] delivered 120.01 fps with no video PTS gaps and embedded IMU. The app now probes K availability per format and prefers a K-capable `420v` equivalent with the same codec, raster, FPS and autofocus system. Settings explains the crop or missing-K status. A normal relaunch restored remembered 1080p120 as format [32] and reported successful camera configuration. This is physical evidence for iPhone 12 HEVC only; other devices require their own verification.

At 1080p240, both ultra-wide [34]/[35] and wide [34]/[35] report no K support through the current `AVCaptureVideoDataOutput` connection. No equivalent K-capable 240 fps format was exposed on either lens. The 10-second wide-camera video-only recording played/decoded, had AAC audio and no video PTS gaps, but cannot serve as a one-file Gyroflow clip. The HUD now labels this state `!IMU`, and Settings states that IMU cannot be embedded. Raw IMU remains in `Log` for diagnostics.

## Fixes and safeguards

- Manual ISO and shutter intent now survives physical-lens and frame-rate switches. The target camera clamps shutter time to the frame period and its exposure limits, and ISO to its supported range. Manual shutter angle is recalculated for the new FPS.
- iPhone 12 1080p120 previously refused to start when the chosen format reported no intrinsic-matrix delivery. The recorder can still permit video/audio capture at >=100 fps without K, set the IMU viewfinder badge red, retain raw IMU in `Log`, and mark that clip without embedded IMU. The preferred [32] format now avoids this fallback on the tested camera. It does not synthesize K. The badge change was built but not visually checked on the device.
- MOV finalization now rejects severe cadence discontinuity (>100 ms gap or >5% estimated missing frames) and reports the problem. It preserves the original MOV and recovery data. Ordinary K callback loss remains distinct from MOV frame loss.
- Sony MOV metadata records maximum video-frame gap, estimated missing frames, and maximum gyro/accelerometer sample gaps for later investigation.

Physical exposure smoke at 0.5×→1×: manual 1/50 and ISO 400 settled to 1/50.01 and ISO 400.06. Changing to 120 fps settled to 1/122.0 and ISO 400.06 (device quantization). A separate 180° angle run settled to 1/60.02 at 30 fps, then 1/240.21 at 120 fps, with ISO 400.06 retained. All values are measured device readbacks after a one-second settle.

Simulator unit suite `DefaultsAndOrientationTests`: 20 passed, 0 failed. iPhone 12 Debug and generic iOS Release builds passed. The latest Debug build was installed, then launched normally on iPhone 12 with camera configuration success and no startup error. Video files and diagnostic logs remain on the phone as `UITEST_` artifacts for review; no original media was removed.

## Still open

- ProRes RAW 4K120, RAW playback on Windows DaVinci Resolve, SSD behavior, and the iPhone 17 Pro camera pipeline need supported hardware and an SSD. HEVC results cannot establish RAW compatibility.
- The new 1080p120 K-capable MOV contains video, audio and Sony `rtmd`, but Gyroflow stabilization/export with this cropped view has not been visually checked. Formats [34]/[35] still cannot supply measured K. Their `!IMU` fallback remains deliberate if no equivalent K-capable format exists.
- iPhone 12 1080p240 remains video/audio-only through this AVFoundation capture path. A calibrated K fallback would require separate validation for each lens, crop, zoom and focus state; no K is synthesized from another format.
- Stabilization can still be wrong because lens distortion and exposure-center/optical timing are not calibrated. A moving scene and the specific problematic MOV/Gyroflow project are needed to isolate those effects.
