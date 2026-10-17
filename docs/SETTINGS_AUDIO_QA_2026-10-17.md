# Settings, Media and stereo audio QA — 2026-10-17

## Baseline
- Committed and pushed `c5c8317` to `origin/master` before this round of changes.

## Changes
- Settings selections expand inline on the same page; choosing an option applies it and collapses the list. Updated after user feedback that navigation required too many steps.
- Media Done hit areas enlarged; player IMU overlay does not intercept touches.
- Thumbnail decoding runs serially on a dedicated actor; canceled queued requests skip decoding.
- Enable stereo microphone capture when supported. RAW Writer AAC target is 320 kbps for stereo, 128 kbps for mono.

## Verified
- Debug and Release device builds and Debug simulator build succeeded; `git diff --check` passed.
- Release installed and launched normally on connected iPhone 18 Pro Max, iOS 27.0.1.
- Previous HEVC sample was mono (48 kHz, one channel).
- New HEVC 4K60 recording: 48 kHz stereo, approximately 208 kbps; decoded L/R samples differ. IMU finalization completed.
- New RAW recording: 48 kHz stereo, approximately 327 kbps; all 152 video frames decoded with AVAssetReader. Capture reported zero drops, peak buffered frames 1, and IMU finalization completed.

## Evidence on this Mac
- `/tmp/gyrocine-stereo-hevc.log`, `/tmp/gyrocine-stereo-hevc.mov`
- `/tmp/gyrocine-stereo-raw.log`, `/tmp/gyrocine-stereo-raw.mov`
- `/tmp/gyrocine-stereo-raw-decode.log`
- `/tmp/gyrocine-choices-audio-build.log`, `/tmp/gyrocine-choices-audio-release.log`

## Limits
- Settings selection feel and Media Done responsiveness have not passed interactive regression. XCTest driver connection was unreliable; simulator UI launch was unavailable. Build success is not UI acceptance.
- Concurrent thumbnail load was reduced; it is not confirmed as the sole cause of missed Done taps.
- External microphone and unsupported-stereo device fallback were not physically tested.
- This round of fixes remains uncommitted after the requested baseline push.
