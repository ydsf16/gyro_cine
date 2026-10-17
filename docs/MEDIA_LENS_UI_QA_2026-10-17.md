# Media playback and immediate lens selection — 2026-10-17

## Changes
- Capture setup uses explicit lens buttons. Selection applies immediately; “Close” only dismisses the sheet.
- A local pending request disables lens/video controls immediately, before the capture queue starts. Completion always returns on the main queue, including early rejection or failure, and releases the pending UI state after the session operation finishes.
- The selected lens remains the actual camera selection. Existing capability matching and rollback remain in place.
- Media playback owns one AVPlayer in a StateObject per presented URL. Live camera updates no longer construct a new player. Dismissal pauses playback.

## Device evidence
- iPhone19,7, iOS 27.0.1; Release configuration.
- `/tmp/gyrocine-lens-player4.xcresult`: `testImmediateLensSwitchAndPlayback` passed.
- H.265 4K60: three 1×→4×→1× rounds; selected state and enabled controls verified before closing setup.
- `/tmp/gyrocine-lens-final-logs/focus-C97FE97B-1D05-4A5C-8026-6D1A6B2AB791.jsonl`: six successful physical lens-switch results, codec hvc1.
- Existing RAW `IMG_0006.mov` opened and played to its end. Native AVPlayer accessibility reported elapsed 3 seconds, remaining 0; no reset to the first frame during live camera updates. No user media deleted or changed.
- `/tmp/gyrocine-lens-player-release-build.log`: normal signed Release build succeeded.

## Test iteration notes
- First attempt found that the HStack accessibility identifier propagated to every lens button; removed the parent identifier.
- Second attempt completed lens switching but had no UITEST clips available; playback now reads an existing clip without modification.
- Third attempt needed a tap to reveal native playback controls; fourth attempt passed.
- This is targeted UI/playback regression, not a new recording/IMU/AF acceptance matrix.

## Final extended run
- `/tmp/gyrocine-lens-player5.xcresult`: passed, with an explicit elapsed-time > 0 assertion.
- H.265 4K60: three switch rounds; ProRes RAW 60fps: two additional switch rounds, all before closing the setup sheet.
- `/tmp/gyrocine-lens-raw-final-logs/focus-C97FE97B-1D05-4A5C-8026-6D1A6B2AB791.jsonl`: six hvc1 and four aprn successful lens-switch results, each at 60fps.
- XCTest waited twice for the system codec-menu animation timeout, then continued successfully. This increased test duration to about 173 seconds; it was not a failed lens switch.
- Normal signed Release app installed successfully after testing; user media retained.
