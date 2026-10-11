# Capture thread, timestamp and focus audit — 2026-10-11

## Installed build

Installed and launched on iPhone 17 Pro at 18:55–18:57; installation database sequence 15612. Includes SSD synchronization fallback. SSD is currently mounted on the Mac as /Volumes/PortableSSD; post-fix phone+SSD recording is pending.

## Code findings

- MotionRecorder uses a serial OperationQueue for gyro and accelerometer callbacks. CaptureCoordinator uses capture.samples for video and audio, separate from capture.session. These are separate queues, not dedicated real-time hardware threads.
- Both motion JSON encoding/writes and per-video-frame evidence writes execute synchronously in their respective callback/drain queues. StagedRecordingLog stages both on internal Application Support/PendingTelemetry and publishes after recording. SSD logging does not directly block the IMU queue during capture, but internal filesystem/CPU contention remains possible. Therefore absolute non-interference is not established.
- IMU timestamps are CoreMotion sample.timestamp. Video uses CMSampleBufferGetPresentationTimeStamp, converted from session.synchronizationClock to CMClockGetHostTimeClock. Copies preserve CMSampleTimingInfo. Queue drain never substitutes arrival or write time for sample timestamps.
- This is system timestamp/timebase alignment, not a documented common sensor hardware trigger. ClockEvidence explicitly records hardwareReadoutTimeKnown=false. Exposure half-duration correction is a separate optical timing approximation; callback-time exposure values do not identify exact per-frame exposure start.
- Delayed callbacks should not rewrite sample time. Overload can still cause missing samples/frames and hence gaps. Existing capture drop count, pending queue peak, monotonic timestamps and MOV timeline validation detect some failures. Only the first video callback latency is currently logged; full per-callback scheduling latency is not measured.
- Shared camera configuration applies continuousAutoFocus when supported after every input/format change; requests initial autoFocus first. The same configuration covers HEVC, RAW, RAW HQ. Unsupported lenses cannot be promised continuous AF. Per-frame focusMode, lensPosition, isAdjustingFocus are recorded. A mode value alone does not certify image sharpness.
- Stabilization is disabled on the video output. Do not equate this API setting with an independently verified physical OIS state.

## Actual retained SSD recording

Source: /Volumes/PortableSSD/DCIM/GyroCine_20261011_180258
Lens: 0.5x ultra-wide; codec ProRes RAW; 4224x2240, 60 fps; 2157 submitted frames.

| Observation | Result |
|---|---|
| Video timestamp interval min / median / max | 16.6562 / 16.6735 / 16.6907 ms |
| Gyro interval min / median / max | 10.004 / 10.005 / 10.006 ms |
| Accelerometer interval min / median / max | 10.004 / 10.005 / 10.006 ms |
| Non-increasing timestamps | 0 in each stream |
| Capture dropped callbacks | 0 |
| Pending video queue peak | 1 |
| Focus mode over all submitted frames | 2 (continuousAutoFocus) |
| Lens position range | 0.8235294–0.84705883 |
| Active video stabilization mode | 0 (off) |

The recording failed at metadata synchronization, after capture completed. This dataset does not show acquisition gaps or time reversals. It is a pre-fix recording and does not validate the new synchronization fallback.

Device capability snapshots copied to artifacts/device-audit-1857 include hvc1/aprn/aprh entries, each reporting continuous AF supported, focusMode=2, stabilization=0. These are last-configuration snapshots, not an all-lens/all-mode acceptance matrix.

## Remaining device checks

For 0.5x/1x/4x with each supported codec, record a short near-to-far scene, inspect frame focus state and visible sharpness, and compare timestamp gaps and dropped callbacks. Repeat RAW on phone-attached SSD with the new sync fallback. Do not mark untested combinations passed.

References:
- https://developer.apple.com/documentation/avfoundation/avcapturesession/synchronizationclock
- https://developer.apple.com/documentation/coremotion/cmlogitem/timestamp
