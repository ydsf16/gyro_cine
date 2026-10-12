# GyroCine rebuild baseline

This app is a separate, installable copy of `RAWFocusTest`'s camera implementation.
Its `Sources` directory was copied without changes. The project configuration only
changes the app name and bundle ID so it can run beside the existing GyroCine.

## Acceptance gate

On iPhone 17 Pro, select `aprn`, Format [69] (4224×3024), 30 fps, and Continuous AF.
After a cold launch, move between textured subjects at 30–50 cm and over 1 m for
30 seconds, then repeat after two 4×→1× switches.
Inspect both visible sharpness and the session JSONL focus events. A build alone
does not pass this gate.

## Rebuild constraints

- Keep the known-good camera session path intact while adding one feature at a time.
- Preserve a single Sony-compatible MOV with embedded IMU and lens information as
  the final recording deliverable. No required sidecar or post-capture re-encoding.
- Add UI, additional physical lenses, motion capture, metadata muxing, and storage
  in separate stages. Re-run the autofocus gate after each stage.
- Keep the old GyroCine app and its recordings available until the replacement has
  passed device recording and Gyroflow checks.

## Device result, 2026-10-13

- The unchanged RAWFocusTest camera source passed continuous 1× RAW [69]/30fps
  near/far focus on iPhone 17 Pro. The session log contained 428 lens-position
  changes over roughly 65 seconds; the user saw sustained optical refocus.
- First lens-switch implementation failed after returning to 1×. Logs showed
  the saved UI selection was 30fps, while the active camera frame duration had
  reset to 1/60 second. Reapplying format, frame duration, and codec together on
  return fixed that mismatch.
- The corrected build passed repeated 4×→1× switching and near/far focus. Each
  return to 1× read back `aprn`, format [69], 1/30 second, continuous AF. In the
  final 28.6-second 1× interval the focus position varied from 0 to 0.745; the
  user reported sustained visible refocus. This gate covers preview only.
- A microphone-input candidate is built and installed separately. Its RAW AF
  behavior and HEVC audio/video save still require device acceptance before
  further recording features are added.
