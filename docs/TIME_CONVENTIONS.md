# Time conventions

- CoreMotion gyroscope and accelerometer `timestamp` values are persisted unchanged in `imu_raw.jsonl`. Values are seconds from a system monotonic clock, not callback arrival times.
- `AVCaptureVideoDataOutput` sample PTS is fed directly to `AVAssetWriter`. At the first video callback, the app records the sample PTS and `CMClockGetHostTimeClock()` value; their difference is diagnostic evidence only.
- After MOV finalization, `AVAssetReader` enumerates **actual encoded video samples** in playback PTS order. `frameNumber` is 1 through this actual count. The sidecar's `fileFrameRate` is the mean observed rate. Any interval more than 5 ms from 1/30 s fails finalization: Gyroflow reconstructs a constant frame timeline from `frameNumber` and rate, which would otherwise misrepresent VFR or dropped frames.
- Sidecar IMU `sampleTimestampUs = (CoreMotion timestamp - first source video PTS + first asset PTS) × 1e6`. This assumes CoreMotion timestamps and video PTS share a monotonic host epoch. The app refuses finalization when the first video callback host-clock difference exceeds two seconds. A smaller difference does **not** prove exposure-level sync.
- `startTimestampUs` and `endTimestampUs` are omitted. MOV PTS is a presentation time, not measured first/last sensor-row readout time. `frameReadoutTimeUs`, exposure timing and OIS data are also omitted.
- Each original gyro or accel event appears once on the union timestamp stream in JSONL. The other sensor's latest value is held; before its first arrival, its first observed value is used. `imu_raw.jsonl` distinguishes true event type and preserves raw values. This resampling rule is provisional for Gyroflow acceptance tests.
- Gyro values are rad/s × 180/π. Acceleration is CoreMotion raw g × 9.80665 m/s²; no orientation rotation is asserted until axis calibration.
- Physical motion sync offset, sign mapping and frame readout remain unmeasured. Gyroflow motion sync must be performed on-device footage before claiming useful stabilization.

## Observed reader limitation

The pinned official parser emits FirstFrameTimestamp from non-optional start_timestamp_us, which defaults to zero when omitted. Its generated per-frame offset becomes negative playback PTS. Latest Gyroflow applies these offsets when looking up motion; successful schema parsing is therefore insufficient to establish usable synchronization. Do not treat this sidecar as verified stabilization input until reader handling or an explicitly documented estimated/offline timing workflow is validated.

Confirmed on official nightly 1.6.3 (gh2733): parsed metadata has 675 offsets from 0 to approximately −22,465 ms and has_accurate_timestamps=true. This is a reader-level blocker, not merely an unmeasured fixed sync offset.
