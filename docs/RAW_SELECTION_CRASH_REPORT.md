# RAW selection crash and deferred destination validation

2026-10-11. Two device crash reports (19:08:09 and 19:08:18) show an uncaught Objective-C exception within the AVFoundation RAW configuration query, called from CaptureCoordinator.configure. Swift do/catch cannot catch NSException.

Changes:
- Removed the internal-storage settings probe from camera configuration. Selecting RAW/HQ does not query an internal output URL.
- At recording start, use the actual destination URL and writer; enable public Pro Video Storage support when available. Removed the previous UI guard requiring a positive settings-time probe.
- Wrapped RAW recommended settings and movie metadata queries with a narrow Objective-C exception bridge that returns NSError with the original reason. Nil results also become errors.
- An internal RAW settings rejection offers an alert with a button to open recording settings and choose SSD. No silent destination switch.
- Existing explicit SSD selection/authorization checks remain; no SSD can be inferred or authorized merely by selecting RAW.

Validation:
- Signed device build passed.
- 48 unit tests passed, including real AVFoundation invalid-codec exception conversion for settings and metadata (artifacts/raw-crash-tests.log).
- iPhone 17 Pro UI test passed: select RAW, RAW HQ, HEVC; application remains foreground and configuration completes (artifacts/raw-selection-device-test.log).
- Actual recording-start rejection alert and internal RAW capture on a supporting system remain separate unverified hardware cases. SSD synchronization fix also requires phone-attached SSD recording.
