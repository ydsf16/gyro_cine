# SSD sustained-write and capture diagnosis — 2026-10-17

## Device and transport
- iPhone 18 Pro Max / iPhone19,7 / iOS 27.0.1, PortableSSD attached directly to phone.
- devicectl confirmed localNetwork/TCP control. SSD writes happen on phone, not through Wi-Fi.
- Original user MOV and IMU/K files retained. File-transfer socket failures prevented retrieving the full session log; a temporary debug-only exporter summarized it through the device console. That one-off exporter was removed afterward.

## Original recording
- IMG_0001.mov, ultrawide, RAW HQ aprh, 4224x2240, 60fps.
- MOV index: 122.705s, 5,970 frames, 33,840,378,720 bytes, average48.653fps, 1,389 estimated missing frames, maximum gap600ms; audio track present, telemetry absent.
- Capture callback count1,407 drops; callback count differs from indexed PTS missing count. Session-wide reasons:2 FrameWasLate,2,085 OutOfBuffers (includes earlier takes).
- This take: app writer buffer peak4, max append6.733ms, max metadata5.476ms. All123 health samples showed thermalState1 / system pressure nominal; requested frame duration stayed1/60.
- IMU finalization rejected heavy PTS loss; raw IMU and K retained. Do not describe this as a complete recording.

## Non-destructive phone-side SSD benchmark
- New system-provided IMG_0002.tmp, exclusive creation, 8GiB total,8MiB random-data blocks, synchronize every512MiB. Camera session stopped during benchmark.
- First six windows660.98–698.31MB/s. Later steady windows237.18–297.99MB/s. Whole test337.54MB/s including synchronization.
- Longest8MiB write668.29ms; flush up to1,314.19ms.
- Temporary file removal confirmed. No existing media overwritten.
- This is this phone/cable/drive path, with explicit flushes. It does not isolate NAND cache, controller thermal throttling, cable or filesystem, nor establish indefinite steady-state bandwidth.
- Original take's observed average frame size implies roughly340MB/s at full60fps. Later benchmark throughput is lower, consistent with capture OutOfBuffers. A10-frame ingress buffer cannot compensate sustained insufficient throughput or writer-held camera buffers.

## Fixes
- RAWCadenceGuard observes source PTS over five-second windows and stops when missing frames exceed5%; both discrete missing intervals and uniform cadence slowdown are covered. Isolated sparse losses do not trigger the guard. Original partial recording is retained with an explicit error.
- Register SSD media bookmark before capture; pending-IMU jobs also contribute external media URLs. A failed IMU job no longer hides its MOV. Resolve usable stale bookmarks, deduplicate URLs, refresh on reconnect/finalization and pull-to-refresh.
- Catalog covers this installation's known/pending SSD recordings, not arbitrary ungranted folders or all third-party recordings on a disk.

## Regression
- Same ultrawide RAW HQ4K60: IMG_0002.mov reproduced sustained loss and stopped at about20s;37 dropped frames in the final five-second window,1,163 retained frames. Explicit cadence-stop event and original-preservation path verified. Not a successful recording.
- Ultrawide RAW HQ4K30: IMG_0003.mov45.0383s,1,351 frames,6,431,309,968bytes (~142.8MB/s),zero missing/capture drops. All1,351 frames decoded on device, audio1 and embedded telemetry present. This is45s acceptance, not a five-minute endurance result.
- Real-device media view scan:5 entries,3 external, includes problematic IMG_0001 and test IMG_0002/0003. Visual screenshot was back on the viewfinder, so no media-grid visual acceptance claimed.
- Simulator: testRAWCadenceGuardStopsSustainedLoss and testRAWCadenceGuardAllowsSparseLoss passed. Release build passed.
- Test recordings IMG_0002/0003 retained on SSD for inspection.

## Evidence
- Compact events: SSD_SPEED_DROP_2026-10-17.json.
- Local diagnostic logs/raw IMU/K: artifacts/ssd-drop-20261017/ (ignored).
- XCTest: /tmp/gyrocine-ssd-cadence-guard.xcresult.
- Release build: /tmp/gyrocine-ssd-fix-release.log.
