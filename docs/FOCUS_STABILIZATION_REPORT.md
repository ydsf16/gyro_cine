# Autofocus and stabilization — 2026-10-11

## Changes
- Explicit continuous autofocus after configuring the active camera input/format; center focus point and unrestricted focus range where supported. Single autofocus fallback; fixed-focus devices retain their supported behavior.
- Recording video stabilization remains off. Preview now explicitly requests off as well.
- Recording refuses to start if active video stabilization is not off.
- Diagnostic capability JSON records focus mode/support and active stabilization. Frame evidence adds callback-time focus mode, lens position and adjusting-focus state. These are diagnostic device readings, not frame-embedded lens metadata.

## Verification
- Signed device build: passed (`/tmp/gyro-focus-build.log`).
- Simulator unit regression: 37 passed, zero failures (`/tmp/gyro-focus-tests.log`).
- Installation and hardware focus/sharpness: pending; iPhone 17 Pro unavailable at device discovery.
- This configuration does not establish independent physical OIS disablement.

## Device acceptance steps
1. Connect/unlock phone and install this build.
2. In a bright scene, point 1x and 4x at text beyond each lens minimum focusing distance, then a distant textured scene. Verify focus converges in preview and saved clip. Repeat supported 0.5x modes.
3. With diagnostic data enabled, inspect capture capability focusMode (continuous AF = 2 where supported), video_samples.jsonl focus lens-position transitions and isAdjustingFocus, and activeVideoStabilizationMode = 0 for every recorded frame.
4. Repeat HEVC and RAW with SSD attached. Actual focus quality and RAW behavior remain unverified until these recordings are inspected.

## 2026-10-11: all-lens subject-change recovery

- Shared configure path now directly selects continuous autofocus when supported; single-shot autofocus is only a fallback. Removed immediate single-shot-to-continuous toggling, which did not wait for acquisition.
- Subject-area monitoring is enabled for each selected physical device. Its notifications restore center focus point and supported automatic focus mode on the session queue. Old observer is removed during camera reconfiguration and deinitialization; callbacks verify the active device.
- Scope includes 0.5x/1x/4x and all codec modes, subject to each device's AF support. This is a defensive recovery change, not a proven root-cause diagnosis of the reported 1x blur.
- Embedded Sony/protobuf MOV audit note now retains per-recording focus mode set, observed/adjusting frame counts, and min/max lens position. These states cannot certify sharpness.
- Device check: film a textured object at roughly 1 m, then a distant object and back with each lens, in adequate light; repeat after switching away and back. Do not use targets closer than the lens can focus. Check visible focus reacquisition and focus_observation in the MOV note. Fixed-focus devices cannot be given autofocus through software.
- Current phone offline; revised all-lens near/far visual acceptance remains pending.

Update: signed build installed on iPhone 17 Pro (installation database sequence 15660). User will perform visual near/far testing. Simulator regression retry completed successfully (artifacts/focus-scene-tests-retry.log); initial attempt stalled during test launch. Visual AF acceptance is still pending.
