# RAW preview with ordinary internal storage — 2026-10-17

## Observed failure
Device log `BC909E8E-430E-45C1-8F51-A81691AD1816` shows RAW format 68 / 120 fps selected at 18:23:34 CST. Legacy RAW pipeline restart immediately failed, followed by three runtime errors. Later configuration requests were still processed: this evidence confirms a stopped camera session, not a proven main-thread deadlock.

## Fix
On iOS 27+, RAW preview routing depends on codec rather than storage destination. Selecting ordinary internal storage no longer routes RAW back to MovieFileOutput plus the extra intrinsic output. The RAW Writer recording entry rejects ordinary internal storage before waiting for preview or allocating a destination. Dedicated storage / SSD requirements remain enforced.

## Device verification
Connected iPhone 18 Pro Max, iOS 27.0.1; Debug automated probes:
- RAW 4224×2240 / 120 fps + ordinary internal storage: preview ready, session running, Writer route selected; REC rejected with the dedicated storage / SSD message; switching back to HEVC 60 fps leaves session running with no active writer.
- RAW HQ 4224×2240 / 60 fps: same result.
- RAW HQ 120 fps unavailable in this device's reported formats; not tested or claimed supported.

Evidence: `/tmp/gyrocine-raw-internal-stall.jsonl`, `/tmp/gyrocine-internal-raw-guard-test.log`, `/tmp/gyrocine-internal-raw-hq60-guard-test.log`, `/tmp/gyrocine-internal-raw-hq-guard-test.log`.

Probes validate session readiness, invalid-storage rejection and recovery. They intentionally do not write a recording to ordinary internal storage. Physical near/far autofocus and all supported storage recording combinations were not re-tested in this change.
