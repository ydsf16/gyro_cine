# GyroCine rebuild baseline

This app is a separate, installable copy of `RAWFocusTest`'s camera implementation.
Its `Sources` directory was copied without changes. The project configuration only
changes the app name and bundle ID so it can run beside the existing GyroCine.

## Acceptance gate

On iPhone 17 Pro, select `aprn`, Format [69] (4224×3024), 30 fps, and Continuous AF.
After a cold launch, move between textured subjects at 30–50 cm and over 1 m for
30 seconds, then repeat after two 4×→1× switches once lens selection is added.
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
