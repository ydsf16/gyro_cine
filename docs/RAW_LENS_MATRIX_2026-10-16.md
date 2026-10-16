# Physical-lens RAW matrix — 2026-10-16

Device: iPhone 18 Pro Max / iOS 27.0.1; SDK 27.1. Debug dedicated-storage AVAssetWriter path, ProRes RAW (`aprn`), AAC, Sony MOV telemetry. 4K = 4224×2240; Open Gate = 4224×3024. Each supported trial approximately 10 seconds. These are short functional tests, not long-duration, autofocus, optical-sync, or stabilization acceptance. RAW HQ was not part of this matrix.

## First pass

| Lens | Raster | FPS | Result | Frames | Capture drops | Native K frames |
|---|---|---:|---|---:|---:|---:|
| ultrawide | 4k | 30 | Saved | 301 | 0 | 301 |
| ultrawide | 4k | 60 | Saved | 602 | 0 | 602 |
| ultrawide | 4k | 120 | Unsupported | — | — | — |
| ultrawide | opengate | 30 | Saved | 301 | 0 | 301 |
| ultrawide | opengate | 60 | WB readiness failure | — | — | — |
| ultrawide | opengate | 120 | Unsupported | — | — | — |
| telephoto | 4k | 30 | Saved | 301 | 0 | 301 |
| telephoto | 4k | 60 | Saved | 604 | 0 | 604 |
| telephoto | 4k | 120 | Unsupported | — | — | — |
| telephoto | opengate | 30 | Saved | 303 | 0 | 303 |
| telephoto | opengate | 60 | Saved | 605 | 0 | 605 |
| telephoto | opengate | 120 | Unsupported | — | — | — |

Every saved first-pass file completed on-device checks: compressed video PTS, RAW codec, audio track presence, orientation, IMU coverage, native K alignment and indexed telemetry track. All had 0 K failures and 0 long K gaps. Encoder-preparation drops before the MOV start are separate and are not counted as in-recording drops.

Both physical lenses advertise RAW 4K/Open Gate only through 60fps. The four 120fps cells are unsupported, not failures or passes. The harness records actual lens ID and offered RAW formats; it does not silently switch to main camera.

## Ultra-wide Open Gate 60fps failure and retests

First pass: 894 delivered preview video buffers and 650 audio buffers but no accepted WB completion, despite three requests; 15-second watchdog rejected recording. No MOV was started. This remains negative evidence.

Removed the condition that discarded callbacks from an earlier request within the same still-valid preview. SDK documentation says these completions are FIFO; earlier actual confirmation is valid for the unchanged locked preview. Added callback attempt/effective-time logging. This is a defensive correction, not proof that it caused the original missing callback. Three fresh retests:

- retest-ultrawide-opengate-60-1: 603 frames, 0 capture drops, IMU finalized=True.
- retest-ultrawide-opengate-60-2: 601 frames, 0 capture drops, IMU finalized=True.
- retest-ultrawide-opengate-60-3: 601 frames, 0 capture drops, IMU finalized=True.

All original failure logs retained. No claim that three successes eliminate the intermittent OS behavior. Evidence directory: `artifacts/prostorage-20261016/lens-matrix/`. Raw movies retained on device; sampled copies in `/tmp/gyrocine-lens-matrix/`.

## Offline sample verification

- telephoto-opengate-60: 605 frames, K PASS, maximum time matching error 0.840ms; full ffmpeg video+audio decode exit 0. Sony rtmd metadata verified.
- retest-ultrawide-opengate-60-3: 601 frames, K PASS, maximum time matching error 0.841ms; full ffmpeg video+audio decode exit 0. Sony rtmd metadata verified.

Other successful combinations received on-device file validation, not a separate desktop full decode. Final ordinary App launch regained RAW WB readiness on attempt 1. User recordings untouched; no commit/push.
