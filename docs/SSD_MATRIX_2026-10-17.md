# SSD RAW matrix — 2026-10-17

## Scope
- iPhone 18 Pro Max (iPhone19,7), iOS 27.0.1, 1× camera, PortableSSD, Mac connection confirmed `localNetwork` after USB cable removal.
- Baseline commit f23660c; only Debug smoke-test controls and result/decode inspection added. Existing SSD AVCaptureMovieFileOutput recording path exercised.
- Sony MOV output, LUT off. About eight seconds per supported recording. Each successful MOV was fully decoded on-device to BGRA after finalization; no re-encoding or video copy.

| Codec | Resolution | FPS | Result | MOV | Frames / decoded | IMU |
|---|---|---:|---|---|---|---|
| RAW | 4224×2240 | 30 | PASS | IMG_0016.mov | 243 / 243 | True |
| RAW | 4224×2240 | 60 | PASS | IMG_0017.mov | 491 / 491 | True |
| RAW | 4224×2240 | 120 | FAIL: session resource limit | — | — / — | — |
| RAW | 4224×3024 | 30 | PASS | IMG_0018.mov | 243 / 243 | True |
| RAW | 4224×3024 | 60 | PASS | IMG_0020.mov | 491 / 491 | True |
| RAW | 4224×3024 | 120 | Not offered by this output/format combination | — | — / — | — |
| RAW HQ | 4224×2240 | 30 | PASS | IMG_0021.mov | 242 / 242 | True |
| RAW HQ | 4224×2240 | 60 | PASS | IMG_0022.mov | 490 / 490 | True |
| RAW HQ | 4224×2240 | 120 | Not offered by this output/format combination | — | — / — | — |
| RAW HQ | 4224×3024 | 30 | PASS | IMG_0023.mov | 243 / 243 | True |
| RAW HQ | 4224×3024 | 60 | PASS | IMG_0024.mov | 492 / 492 | True |
| RAW HQ | 4224×3024 | 120 | Not offered by this output/format combination | — | — / — | — |

## Findings
- 8 passes, 1 failure, 3 unavailable combinations. All eight passes have one audio track, complete decoded-frame counts, embedded telemetry and zero estimated missing frames from indexed MOV timestamps.
- RAW 4K120 is advertised by the MovieFileOutput format probe, but preparation fails before recording: AVFoundationErrorDomain -11872, requested camera hardware resources are excessive. This is not evidence of insufficient SSD write throughput. No production workaround applied.
- Startup currently uses MovieFileOutput plus a full-sized intrinsics VideoDataOutput. The failure occurs before the separate LUT proxy is added; isolate the intrinsics/output resource combination next. Treat this as a hypothesis, not a confirmed fix.
- RAW HQ 4K120 was not offered by MovieFileOutput capability discovery. This does not establish a device-wide limitation for the separate AssetWriter route.
- File paths are SSD DCIM/100APPLE. All test recordings retained; no existing user media deleted.
- SSD had about 646 GB free at first recording. Successful reported matrix clips total about 10.16 GB.

## Evidence and limits
- Full per-case local logs/results: /tmp/gyrocine-ssd-matrix-20261017/. Compact results: SSD_MATRIX_2026-10-17.json.
- RAW120 full diagnostic: /tmp/gyrocine-ssd-120-diagnostic.jsonl.
- SSD authorization through XCUITest passed: /tmp/gyrocine-ssd-authorize.xcresult.
- Repeated Wi-Fi live-file transfer failures interrupted the first runner. Console streaming then completed the remaining cases; these transport failures are not classified as video failures.
- Current session only: 1×, 30/60/120fps. Other lenses, fractional frame rates, other integer rates, sustained thermal/long recording, hot unplug and desktop-player/Gyroflow import are not covered by this matrix.
- Full decode validates video. Audio-track presence and successful IMU/K finalization are checked, but subjective audio and stabilization quality are not independently validated here.
