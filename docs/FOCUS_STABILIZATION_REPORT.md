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

## 2026-10-11 — RAW 1× close-to-far recovery candidate

User narrowed the reproduction to the physical 1× main camera in ProRes RAW:
place lens close to desk, switch camera/codec, lift toward a textured distant
subject; image remains blurred. Other cameras and HEVC reportedly recover.
The physical-device root cause is not yet established.

Change: RAW/RAW HQ main camera starts one single-shot AF acquisition after
configuration and on subject-area change, observes isAdjustingFocus, then restores
continuous AF after the observed scan ends. A 3-second fallback restores continuous
AF if no completion arrives. Recovery is serialized on sessionQueue, overlapping
requests are ignored, and per-configuration tokens invalidate old completions.
HEVC and other physical cameras retain their existing focus behavior. No repeating
focus sweep or lens reset is added during recording.

Capability diagnostics now include minimumFocusDistanceMillimeters, autoFocusSystem,
autoFocusSupported and rawMainCameraFocusRecovery. Console logs:
`GyroCine RAW AF start reason=... camera=... position=...`
`GyroCine RAW AF continuous reason=scan-ended|timeout ... observedScan=...`
Scan completion is not proof of optical sharpness.

Verification:
- iOS build passed: artifacts/raw-main-focus-build.log.
- Existing 48 unit tests passed: artifacts/raw-main-focus-tests.log.
- Physical AF recovery, sensor KVO behavior, and RAW HQ regression: NOT VERIFIED;
  iPhone 17 Pro was unavailable during this change. Not installed yet.

Device acceptance steps:
1. Choose 1× RAW, hold lens close to a desk for several seconds, switch away/back.
2. Lift toward a well-lit textured target at least one meter away; verify sharpness
   returns and observe the AF start/continuous logs. Repeat 5 times in RAW and HQ.
3. Repeat while recording, then replay MOV to verify recorded sharpness, not only preview.
4. Check 1× HEVC and 0.5×/4× RAW as controls; verify no focus pumping is introduced.
5. Rapidly switch away during acquisition; verify old timeout does not change new lens.

## TestFlight preparation status

Chrome App Store Connect showed only RoamShot and Sensor Recorder Pro. Sensor
Recorder Pro has two groups named “内部测试”; no external group was listed. GyroCine
is not yet registered there. New App is blocked by the updated Apple Developer
Program License Agreement dialog. Account holder action is required. No agreement
was accepted, no build uploaded, and no tester invitation sent.

### Follow-up device result and TestFlight registration

Installed candidate on iPhone 17 Pro at 21:03, installation database sequence 15668.
User reports RAW 1× now focuses once on switching but fails to continue focusing.
Therefore the candidate is NOT accepted as a fix; keep beta distribution pending.
Downloaded device capability snapshots to artifacts/raw-focus-device-2113:
RAW main camera format 65, 4224×2240@60, autoFocusSystem=1 (contrast detection),
autoFocusSupported=true, continuousAutoFocusSupported=true, min focus distance 200 mm.
The focusMode=1 snapshot is taken during initial single-shot acquisition; it cannot
establish what mode remains afterward. Live GyroCine syslog collection started.

Account holder accepted the new agreement. Registered explicit ID
com.tinygrape.RawMotionRecorder under team F2LVFHW3ZH and created GyroCine App
6821620943 (SKU gyro_cine, primary language Simplified Chinese). Created internal
TestFlight group “内部测试”, ID 5dcb6953-88d8-4ec8-9a86-c67cfcc06cc8,
with automatic distribution disabled; zero testers and zero builds.
Release archive succeeded at artifacts/GyroCine-1.0.xcarchive but has not been
uploaded or distributed. External testing setup remains pending.

### Continuous mode readback during reproduced failure

Installed diagnostic build (15676), retrieved artifacts/focus-trace-live2.json and
focus-trace-live3.json while user reproduced the issue. A single acquisition ends
with mode 0, then restoration reads back mode 2. Several subject-area notifications
and single-shot scans were observed; afterward mode remains 2, adjusting=false,
lensPosition=0.20392156 over the last 10 seconds of the retrieved trace. This disproves
an enduring mode=locked explanation for this reproduction. Stable lens position
alone does not certify sharpness or prove a sensor fault.

Next controlled candidate: for RAW/HQ physical main camera only, disable automatic
face-driven AF selection and face-driven AF before requesting continuous AF.
Other capture configurations restore automatic face-driven selection. This tests
whether the face-priority path contributes to stalled contrast AF, not a confirmed
root cause. Installed sequence 15684 and launched 21:27. Build passed in
artifacts/raw-scene-focus-build.log; user optical verification is pending.
Diagnostic ring is bounded to 240 records, written on a separate utility queue;
preview sampling reads state roughly twice per second at 60 fps, with no disk I/O
on the capture callback queue. Logs are under Library/Caches/GyroCineDiagnostics.

### RAW 1× user acceptance

User confirmed on sequence 15684: “能持续自动变清晰” when moving the center
subject between 30–50 cm and more than 1 m. Retrieved
artifacts/focus-trace-scene-success.json: RAW main-camera records all report
faceDriven=false, lens positions span 0.02745098–0.72941172, and acquisition returns
to continuous AF. This accepts the user's RAW 1× reproduction only, not all
formats/lighting or a separate RAW HQ run. Face-priority interaction is implicated
by this controlled change; no claim is made about Apple's internal root cause.
The latest 48 unit tests pass (artifacts/raw-scene-focus-tests.log).
Rebuilt Release archive artifacts/GyroCine-Beta1.xcarchive for TestFlight upload.

### TestFlight build 1 upload

Added MARKETING_VERSION=1.0 and CURRENT_PROJECT_VERSION=1 to project build settings
and project.yml; the generated Info.plist previously omitted them despite literal
values in source Info.plist. Set the app target's device family to iPhone (1),
matching the existing product scope; XcodeGen's target override had included iPad,
which failed multitasking orientation validation. Retained test target families.
Archive artifacts/GyroCine-Beta1-iPhone.xcarchive verifies version 1.0, build 1,
UIDeviceFamily=[1]. Upload succeeded at 21:38:46, Apple processing pending.
Evidence: artifacts/testflight-beta1-iphone-upload.log. Beta description and review
notes saved; reviewer contact reused with user's explicit approval. No public
App Store release was submitted.
