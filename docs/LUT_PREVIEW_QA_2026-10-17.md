# Preview LUT implementation and QA — 2026-10-17

Baseline: `6816330` on master (pushed before feature work). Device: iPhone 18 Pro Max, iOS 27.0.1, SDK 27.1.

## Scope

- LUT tab plus a horizontally snapping Off / RAW → Rec.709 selector. Selected state is blue; HUD marks active conversion. Controls remain available during recording.
- Preview-only output and rendering. Neither recorder, encoding settings, audio, IMU/K processing, exposure/focus controls, file naming, storage nor finalization code is modified.
- RAW preview setup adds a preview-sized AVCaptureVideoDataOutput. The SDK explicitly supports a 4:2:2 RAW proxy with `deliversPreviewSizedOutputBuffers`. Actual device source: x422, 2112×1120, Apple Log 2 attachment (`com.apple.apple-wide-gamut.apple-log`); full RAW recorder stays 4224×2240.
- AVCaptureVideoPreviewLayer remains the fallback and coordinate source for tap/hold focus. Metal surface overlays it only with a current, successfully rendered LUT frame.
- Apple Log and Apple Log 2 are detected from attachments. Rec.709-tagged sources are passed through. Unknown color tags fall back to original preview rather than guessing.
- Technical 33³ lookup table: inverse Apple Log curve, source primaries → Rec.709, smooth SDR highlight shoulder, Rec.709 encoding. This is GyroCine's technical viewing transform, not Apple's proprietary creative LUT. Primaries/curve reference: https://github.com/AcademySoftwareFoundation/OpenColorIO/blob/main/src/OpenColorIO/transforms/builtins/AppleCameras.cpp

## Isolation and responsiveness

- Capture proxy delegate: `GyroCine.LUTPreview`; latest frame replaces the previous one.
- Core Image context creation, shader/command encoding and `nextDrawable()` happen on `GyroCine.LUTRender`, never on the camera or main queue.
- Metal-backed CIContext, a persistent command queue, one GPU job in flight plus one latest-frame slot. Nonblocking semaphore; busy preview work is skipped, never waited on by recording.
- New capture frames schedule rendering directly, capped by a source-frame stride at 60fps (120fps selects every second proxy frame). A no-op CADisplayLink requests 60Hz display refresh only; it does not render or dispatch image work. Three Metal drawable textures avoid display-buffer backpressure; source buffers remain bounded to one in-flight plus one latest. No arrival-time gate or duplicate frame rendering.
- Render surface longest edge capped at 1920 pixels. No full-resolution RAW-to-RGB processing or video re-encoding.
- Foreground guard prevents new GPU submissions while backgrounded. Disabled/stale/unsupported conversion shows the original preview. Generation checks reject work from an old lens/format or disabled LUT.
- `lut_preview_render` records unique-frame FPS, CPU submission mean/max, GPU mean/max, busy skips, output size, and `renderOnMain`.
- GPU/ISP are shared hardware: separate queues eliminate software waiting between preview and recorder, but recording cadence still requires physical validation.

## Evidence obtained

- Proxy probe: `/tmp/gyrocine-lut-probe2.xcresult`, successful streaming through frame 120, proper Apple Log 2 tag.
- Color math: 3 unit tests passed in `/tmp/gyrocine-lut-integrated.xcresult`; inverse transfer reference values, D65 preservation, BT.2020 matrix reference, finite cube, monotonic highlight mapping, identity Rec.709 path.
- Initial UI/record test: `/tmp/gyrocine-lut-integrated2.xcresult`, passed; LUT on/off, toggle during capture, 0.5× / 1× switch, return to H.265. Screenshots exported to `/tmp/gyrocine-lut-screens/`; same orientation and framing with conversion on/off.
- Initial captured `IMG_0002.mov`: 4224×2240 aprn, 60fps, 9.05s, 543 frames, AAC, Sony rtmd track (906 packets). Capture drops 0, writer peak buffer 1, native K 543 frames, IMU finalization success (0.080s). Encoder preparation dropped 7 frames before the recorded interval; not included in MOV.
- Desktop `/tmp/gyrocine-lut-IMG_0002.mov`: complete ffmpeg video+audio decode exit 0 with empty error log. MOV PTS cadence: 543 frames, mean 60.000002fps, max gap 16.667ms, zero gaps/missing frames.

## Final GPU queue regression

The earlier MTKView independent render queue passed 3 unit tests and 2 UI tests in `/tmp/gyrocine-lut-gpu.xcresult`. Subsequent source-driven rendering results follow below.

- RAW120 first case: `IMG_0003.mov`, 757 video frames, zero capture drops, max capture PTS gap 8.354ms, writer peak buffer 1, IMU finalization successful. 15 encoder-preparation drops occurred before the MOV interval.
- Actual render telemetry: `renderOnMain=false`; 884×1920 surface. Steady windows 59.2–59.5 unique frames/s, CPU submission mean 2.8–3.1ms, GPU mean 1.4–1.7ms. Initial context/shader preparation cost 29ms on the render queue, with 3 cumulative busy skips; no growth during subsequent windows.
- HQ30: `IMG_0004.mov`, 191 frames, zero capture drops, max capture PTS gap 33.359ms, writer peak buffer 1, IMU finalization successful. No preparation drops. Steady preview follows the 30fps source (~29.4–29.5 in the sampled telemetry windows), GPU mean ~1.1–1.3ms.
- `testLUTHighRateAndHQ` passed (532.5s; XCTest repeatedly spent 60s waiting for Settings menu animations, not camera configuration).
- Earlier RAW60: `IMG_0005.mov`, 539 frames, capture drops 0, IMU completion successful. This renderer still showed 53–58fps preview windows, motivating the capture-driven revision.

## Capture-driven revision

- Two-drawable trial caused ~18–27ms drawable waits and ~30fps preview despite sub-1.3ms GPU work. It did not drop recorded frames. Replaced with three presentation drawables while keeping one in-flight GPU job; no recorder buffer changes.
- Latest RAW60: `UITEST_IMG_writer_14128986-74E7-4B20-810B-3815191912BB.mov`, 303 frames, capture drops 0, max capture gap 16.695ms, peak writer buffer 1, native IMU packaging completed. Logs: `/tmp/gyrocine-lut-driven60-triple/focus-CAF7B656-EB1F-4E5D-89B9-F137F3C8FC59.jsonl`.
- Preview sustained ~59.5 reported fps for ~90 seconds; telemetry undercounts by about 0.5fps at each two-second window boundary. GPU mean ~1ms, CPU submission including drawable wait ~7ms, renderOnMain=false. Two initial busy skips did not grow.
- Latest RAW120: `UITEST_IMG_writer_FA5722E6-0194-449E-BE16-C69DCCFF7D4E.mov`, 608 frames, capture drops 0, max capture gap 8.353ms, peak writer buffer 1, IMU completion successful. Logs: `/tmp/gyrocine-lut-driven120/focus-9F13E4E4-9EF0-49E6-95DA-76E164CFD8BC.jsonl`. Preview ~59.5 reported fps, GPU mean ~0.4ms, CPU ~2ms, renderOnMain=false.
- Latest HQ30: `UITEST_IMG_writer_DA6178EA-9F2E-4D11-9125-1ADBE96A61B4.mov`, 151 frames, capture drops 0, max capture gap 33.355ms, peak writer buffer 1, IMU completion successful. Logs: `/tmp/gyrocine-lut-drivenHQ30/focus-F1D86D48-4644-40F9-B22B-12EBFCEC486E.jsonl`. Preview follows 30fps source, GPU mean ~0.33ms, renderOnMain=false.
- Latest 60/120/HQ30 recordings used existing Debug automation flags, without changes to its recording implementation. Normal Release UI regression is separate.
- Release carousel/lifecycle XCUITest passed: `/tmp/gyrocine-lut-final-carousel.xcresult` (58s). Swipe to Off, swipe to Rec.709, background/resume, close/reopen panel; no alerts. Screenshot inspected: `/tmp/gyrocine-lut-final-screens/2EFDBB42-EA10-4A04-80AC-AFD18A1DB40B.png`.
- Latest 60fps MOV `/tmp/gyrocine-lut-final60.mov`: full video/audio ffmpeg decode exit 0, empty error log. 303 video frames, AAC + rtmd. Indexed PTS median gap 16.667ms, maximum 18.333ms, no missing frames. `/tmp/gyrocine-lut-final60-cadence.json`.
- Latest 120fps MOV `/tmp/gyrocine-lut-final120.mov`: 608 video frames, AAC + rtmd; indexed PTS median gap 8.333ms, maximum 10ms, no missing frames. `/tmp/gyrocine-lut-final120-cadence.json`. Full video/audio ffmpeg decode completed with exit 0 and an empty error log (`/tmp/gyrocine-lut-final120-decode.log`).
- K health logs match 303/608/151 frames respectively, failedFrames=0 and longGapCount=0.
- Final normal Release build succeeded, installed and launched on attached iPhone. No automatic test recording flags remain on this launch.

## Limits

Short capture checks do not certify long-duration thermal behavior, optical autofocus, calibrated color accuracy, external SSD combinations or other iPhone models. No user recordings deleted. No LUT baked into delivered recordings.
