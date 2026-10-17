# SSD RAW Writer QA — 2026-10-17

## Scope and implementation
- iPhone18 Pro Max (iPhone19,7), iOS27.0.1, 1×, PortableSSD. SSD tests used wireless debugging; final internal regression used USB.
- iOS27+ SSD RAW/HQ now uses the existing native RAW VideoDataOutput + AVAssetWriter path. Dedicated storage enables usesProVideoStorage; SSD leaves it false. H.265 and pre-iOS27 SSD routing remain unchanged.
- Native RAW samples supply K. Existing Writer preparation removes the redundant full-size K output. Audio, orientation and IMU finalization use the shared pipeline; video is not re-encoded or moved after recording.
- Security-scoped SSD access is retained through recording. Recovery bookmark creation now happens during encoder preparation, before the first recorded sample. Actual first-frame timestamp still determines the pending IMU job.
- Video buffering remains bounded at10 frames. Stop/completed callbacks are excluded from capture-drop accounting. Disconnect/write failure ends capture and preserves raw artifacts.

## Physical results
All completed recordings below were fully decoded on the phone; indexed and decoded frame counts agree. Audio1 and embedded telemetry are present unless stated otherwise.

| Test | Result |
|---|---|
| RAW4K4224×2240 30/60fps | Pass, IMG_0026/0027,244/484 frames, zero estimated missing frames |
| RAW Open Gate4224×3024 30/60fps | Pass, IMG_0028/0029,243/486 frames, zero missing frames |
| RAW HQ4K30/60fps | Pass, IMG_0030/0031,244/483 frames, zero missing frames |
| RAW HQ Open Gate30/60fps | Pass, IMG_0032/0033,243/483 frames, zero missing frames |
| RAW4K120 after bookmark fix | Pass, IMG_0037,966 frames, zero missing frames |
| RAW4K120 two minutes after fix | Pass, IMG_0038,120.0467s,27.637GB,14,399 frames, zero missing frames, native captureDrops0, buffer peak1 |
| RAW4K30 three minutes | Pass, IMG_0042,180.038s,5,400 frames, zero missing frames |
| Insufficient capacity before REC (injected) | Correctly rejected before recording |
| Capacity falls during REC (injected) | Clean stop, IMG_0036,3.733s,112 frames, zero missing frames, audio/IMU retained |
| Writer backpressure (injected) | Stops at10 pending frames; IMG_0040 retains5 appended frames and is not marked IMU-complete |
| Retry after backpressure, same process | Pass, IMG_0041,8.035s,241 frames, zero missing frames; Debug driver invoked the normal toggleRecording path without relaunch |
| Physical SSD unplug | IMG_0043 stops around39.6s with AVFoundation-11800/POSIX6 Device not configured; explicit interruption shown, App remains alive |
| Physical reconnect and manual retry, same process | Pass, IMG_0044,5.9683s,179 frames, zero missing frames, audio/IMU complete |
| Dedicated-storage RAW4K60 regression (USB) | Pass, UITEST_IMG_writer_2F02BFFA-59B0-4BBB-8D12-973EB3E2887C.mov,5.035s,302 frames, zero missing frames |
| Internal H.2654K60 regression (USB) | Pass, UITEST_IMG_2026-10-17-15-36-02.mov,20.1483s,1,209 frames, zero missing frames |

RAW Open Gate120, HQ4K120 and HQ Open Gate120 were not offered by the current codec/format capability query. This does not establish a device-wide hardware limitation.

## Startup drop diagnosis
- Before fix, SSD RAW4K120 short clips lost one frame; the first two-minute clip IMG_0034 lost two frames. Do not use these as zero-drop acceptance.
- Timing isolated external recovery setup at14.806ms, versus1.021ms for first native metadata/append. A120fps frame budget is8.33ms.
- Moving the14.574ms bookmark operation into encoder preparation reduced post-first-frame job setup to1.120ms. Short and two-minute regressions subsequently showed zero missing frames.
- Original captureDrops39 in IMG_0034 included37 notifications after Stop; correcting accounting does not erase the two gaps confirmed in that MOV.

## Test limitations and retained artifacts
- Interrupted IMG_0043 remains a failed recording with durable IMU/K logs. Readability/full recovery is not certified. Existing recordingFailure policy prevents falsely reporting successful IMU packaging.
- XCUITest testSSDWriterBufferFailureThenRetry built but two wireless runs failed before bootstrapping: DTX channel refused/IDE disconnection/runner exit74. UI automation is not marked passed; same-process capture recovery was verified by Debug hooks, and reconnect recovery by user operation plus file inspection.
- Early internal smoke attempts fired before session/recovery readiness and did not record. Debug drivers now wait for session.isRunning and idle recovery with a bounded deadline. Production startup has no new fixed delay.
- Low-space and buffer-backpressure tests are injected; the SSD was not physically filled. Other lenses, fractional rates, indefinite thermal runs, desktop-player/Gyroflow stabilized export and subjective audio quality are outside this acceptance.
- All user and test media retained.

## Evidence
- Compact per-case results: SSD_WRITER_QA_2026-10-17.json.
- Full logs/results: /tmp/gyrocine-ssd-writer-20261017/.
- Prior MovieFileOutput comparison: SSD_MATRIX_2026-10-17.md/json. RAW4K120 previously failed before recording with-11872.
- XCTest results: /tmp/gyrocine-ssd-retry-20261017.xcresult and /tmp/gyrocine-ssd-retry-20261017-b.xcresult.
- Latest Release build: /tmp/gyrocine-ssd-writer-final-release-build.log; BUILD SUCCEEDED.

## Delivery
- Latest ordinary Release installed successfully over USB and launched without Debug smoke arguments. Existing media retained.
