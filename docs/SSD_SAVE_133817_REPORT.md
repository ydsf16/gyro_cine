# SSD stop/save diagnosis — 2026-10-11

## Source (read only)
`/Volumes/PortableSSD/DCIM/GyroCine_20261011_133817`

- ProRes RAW (`aprn`), 4224×2240, requested 60 fps; 2097 submitted frames; 7,166,584,010-byte MOV.
- Dropped-frame callbacks: 0. Finalizing 05:38:52Z; failure 05:39:05Z.
- Recorded failure: `The file couldn’t be saved.` No underlying domain/code recorded by the old build.
- GCSV, lens profile and Gyroflow project exist; embedded metadata and recovery journal absent. Video contains original ftyp, mdat and moov. Failure is consistent with the embedded export stage; exact syscall is not established.

## Changes
- Traverse AVSampleCursor timestamps rather than reading every compressed frame. Keep reader fallback for unsupported assets, and all existing cadence/clock/frame-count checks.
- Keep Apple RAW security-scoped file access alive through MOV metadata finalization, then release on both success/failure. Device validation is required to determine whether this resolves the write error.
- Record writer completion, archive/log publication, MOV inspection and finalization-stage durations. Preserve NSError domain/code/details on save failures.

## Measurements
On Mac, using the original SSD movie:
- Cursor: 2097 timestamps, 0.000265 seconds traversal (asset loading excluded).
- Reader: 2097 timestamps, 14.764 seconds read loop.
- Timestamp arrays match exactly; reader completed.
- These timings are not a measurement of full iPhone save latency.
- Sparse local replica of the original >4GB MOV atom layout accepted metadata append successfully; the original SSD recording was unchanged. This does not validate iOS storage authorization.

## Build and regression
- Signed iOS build passed (`/tmp/gyro-ssd-save-build.log`).
- 38 unit tests passed, zero failures (`/tmp/gyro-ssd-save-tests.log`), including cursor/reader equivalence and metadata append/recovery.

## Pending device acceptance
Install new build; connect SSD; record RAW 4K60 for approximately 34 seconds in Sony MOV mode. Confirm saved single MOV, embedded IMU/lens import, no failure and measure stop-to-save time. If failure recurs, retain full folder with new stage/error diagnostics. No SSD device acceptance is claimed yet.
