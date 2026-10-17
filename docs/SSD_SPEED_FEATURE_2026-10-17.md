# SSD speed test feature — 2026-10-17

- Settings > Storage > External SSD > SSD speed test. Native Form with progress, cancel and upper-right Done.
- Measures8GiB in8MiB writes, flushes each512MiB; reports overall average, minimum of last8 windows, maximum write and flush latency. Requires test size+5GB reserve (~14GB free).
- Exclusively creates a temporary system-provided SSD URL, never overwrites existing files. Normal completion, cancellation and errors close/delete the created file; cleanup failure identifies the remaining filename. Forced process kill/power loss cannot guarantee immediate cleanup.
- Background/inactive lifecycle cancels. Capture/configuration blocked during measurement; disk IO runs on a utility queue. Progress on main thread.
- Required throughput uses the existing device/lens/codec/resolution/FPS statistics with conservative fallback, explicitly labeled estimated. Current configuration is shown using product codec names.
- Assessment: below required throughput -> insufficient; less than30% headroom or write stalls exceeding10 frame periods -> risk; otherwise usable. Benchmark cannot certify indefinite recording, encode capacity or any other drive/cable/thermal state.
- Same-drive result is reused in this app session; reopening/changing selected configuration updates requirement and assessment without rewriting test data. A different/unavailable drive clears the result. Test timestamp is retained on reassessment.

## Evidence
- Phone iPhone19,7 on Wi-Fi with PortableSSD: production test backend completed8GiB in~26s. Average333.05MB/s, second-half minimum237.66MB/s, max write660.26ms. H.2654K60 estimate31.204MB/s -> risk due to write stalls, not inadequate average bandwidth. Temp deletion confirmed.
- Screen captures: /tmp/gyrocine-ssd-speed-ui.png (80% progress); /tmp/gyrocine-ssd-speed-result.png (result). UI codec spelling and current-configuration heading subsequently clarified.
- Device console: /tmp/gyrocine-ssd-speed-ui-device.log.
- Unit tests: /tmp/gyrocine-speed-ui-tests.xcresult covers assessment and cancellation/exclusive-file preservation. /tmp/gyrocine-speed-midcancel.xcresult additionally verifies cancellation after actual writes cleans the partial file.
- Release build: /tmp/gyrocine-speed-linked-release.log.
- /tmp/gyrocine-speed-linked.xcresult: measurement reuse/configuration reassessment test passed. Release installed on phone; no benchmark/autorecord launch flags in delivered build.

## Codec-route correction
- The ten-frame write-stall heuristic now applies only to the native RAW writer. AVFoundation MovieFileOutput (H.265/H.265 HQ and legacy paths) has no app-defined ten-frame buffering limit; its bandwidth assessment uses sustained throughput/headroom and reports stalls separately.
- Regression:214MB/s vs31MB/s required,668ms stall,H.265 -> usable; native RAW with143MB/s requirement and same stall -> risk. Unknown MovieFileOutput buffering is not presented as known.
- /tmp/gyrocine-speed-route-fix.xcresult: assessment and configuration-reuse tests passed. Build /tmp/gyrocine-speed-route-release.log.

## Recording specification guide
- Lists cached current-lens codec/dimension/FPS combinations (1920 pixels wide and above), grouped by encoding. Does not mutate the camera session.
- Shows estimated write MB/s and recommended sustained MB/s with 30% headroom; labels matching on-device statistics versus conservative fallback.
- Reuses the current SSD measurement for every row; RAW considers the ten-frame stall limit, HEVC does not assume that limit.
- Release build passed; `testSSDSpeedSpecificationGuidance` passed in `/tmp/gyrocine-speed-spec-guide.xcresult` (headroom, HEVC suitability, RAW stall risk, insufficient HQ bandwidth).
- Estimates are guidance, not a measured recording guarantee. No new SSD throughput run was required for this UI change.

## Persistent IMU recovery failure
- Permanent cadence/K validation failures and stored recording failures retire their pending manifest to `.failed-imu.json`; raw MOV/IMU/K are preserved. Retry state now survives app restarts.
- Background recovery no longer raises the same cadence alert each launch. Media retains the missing-IMU indicator and resolves external bookmarks from failed manifests too.
- Missing local MOV jobs retire; inaccessible SSD jobs remain retryable. In-app deletion removes both pending and failed manifests.
- `testPermanentIMUFailureLeavesAutomaticRetryQueue` passed (`/tmp/gyrocine-recovery-retire.xcresult`): retirement persists, preserves media/raw IMU, does not return to pending after deletion, and does not classify disconnected SSD as permanent.
- Release build passed (`/tmp/gyrocine-recovery-retire-build.log`).
