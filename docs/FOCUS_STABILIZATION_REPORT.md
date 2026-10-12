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

### RAW main-camera continuous-only comparison (21:59)

User reports improved acquisition but slow refocus, sometimes speeding up after
shaking the phone. The extra main-camera single-shot recovery was app-added; it
is a possible confound, not an established root cause. Removed both configuration
and subject-change single-shot requests, KVO completion switching and the 3-second
timeout. RAW/HQ main-camera now stays in continuous AF when supported, with the
previous face-priority disablement retained. Subject changes are logged only,
without setting focus mode or focus point again. Other cameras keep their behavior.

Build passed: artifacts/raw-continuous-focus-build.log. Existing unit regression
passed: artifacts/raw-continuous-focus-tests.log. Installed on iPhone 17 Pro,
sequence 15692. Optical speed/accuracy acceptance is pending user retest.
Test RAW and HQ 1x: change a central textured target between 30–50 cm and >1 m
without shaking; repeat after lens switching and during recording. Verify mode=2
and subject-area-change-observed in focus_trace.json; compare actual sharpness,
not merely stable mode readback. TestFlight 1.0(1) does not contain this change.

### Build 2: preferences, REC feedback and gravity fallback

- Persist codec, physical lens ID, audio, maximum exposure and automatic/manual WB
  temperature/tint; persist dimensions/FPS independently for each lens and codec.
  On launch resolve against current capabilities, never reuse a saved format index.
  Existing output/debug preferences and SSD bookmark remain; a missing SSD no
  longer silently changes the saved location to Files. ISO remains automatic.
- Fix a definite silent REC rejection: the original gravity gate returned while
  its message was only rendered for failed states. Recording direction now uses
  the dominant gravity X/Y component, reducing the old 0.55g/0.1g gates to a 0.01g
  near-flat noise floor and numerical tie check. Flat/ambiguous/missing data uses
  the last unambiguous gravity direction, or landscapeRight when none exists.
  Direction freezes at REC and never consults the UI orientation/rotation lock.
- Separate serial orientation monitoring remembers gravity while previewing; raw
  IMU logging is unchanged. Record start diagnostics identify the direction source.
- REC shows a spinner during preparation/finalization; explicit rejected-start
  notices are visible. Configuration requests arriving during setup are queued.
- 53 unit tests passed: artifacts/preferences-flat-final-tests.log. Includes
  preference reload, missing SSD/invalid stored settings, small tilts and flat
  gravity fallback. Signed Release archive succeeded: artifacts/GyroCine-Beta2.xcarchive.
- iPhone 17 Pro UI tests passed: frame-rate change -> terminate -> launch retains
  selection (artifacts/preferences-device-test.log); HEVC start/stop/save passed
  (artifacts/record-button-device-test.log). Original storage was Files and remains
  Files; original RAW codec restored after the HEVC test. Latest app launched.
- Saved GyroCine_20261011_221410.mov: HEVC 3840x2160, 255 frames, 4.251667s,
  90-degree presentation transform, AAC and embedded Sony RTMD. Copy and ffprobe
  evidence: artifacts/preferences-start-device.mov and *-probe.json. This test
  does not establish physical flat-phone orientation; that behavior has unit
  coverage and still needs user optical acceptance.
- RAW/SSD capture and continuous-only RAW 1x focus speed remain separate pending
  physical checks. Earlier 22:08 RAW/Files failures explicitly report Apple's
  external-storage requirement (artifacts/start-rejected-220803.log).
- TestFlight 1.0(1) added to existing internal group (2 testers), verified Testing.
  Build 1.0(2) upload succeeded 22:15:36; processing/internal assignment pending.

Build 1.0(2) processing and export compliance completed. Assigned to the existing
internal group; App Store Connect verifies "正在测试", 2 testers, both invited.
Build-specific test notes saved. External Beta Review remains on 1.0(1);
no new App Store Connect users or broader permissions were added.

### TestFlight 1.0(3) — 2026-10-12

Archived Release from commit `e657966` as an iPhone-only 1.0(3) build and
verified its bundle ID and code signature. Xcode reported upload success at
01:45:39 China time (`artifacts/testflight-beta3-upload.log`). App Store
Connect completed processing and export compliance. The build-specific test
notes state that 1× RAW continuous autofocus remains under verification;
they do not claim the focus issue is fixed.

App Store Connect shows 1.0(3) in the existing internal group “内部测试” (2
testers) and external group “熟人测试” (1 tester). The old 1.0(1) external Beta
Review request was withdrawn so 1.0(3) could be submitted. The new external
build is **waiting for Beta App Review**; external testers cannot download it
until Apple approves. No testers or public links were added, and no App Store
release was submitted.

## Continuous AF audit: RAW 1× and 4×

Apple's installed iOS SDK AVCaptureDevice.h documents that continuousAutoFocus
is continuous AF, smooth AF is slower (default NO), and face-driven settings
must be changed under the configuration lock before assigning focusMode.
References:
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/issmoothautofocusenabled
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/focusmode-swift.enum/continuousautofocus
- https://developer.apple.com/documentation/avfoundation/avcapturedevice/autofocusrangerestriction-swift.property

Audit found no exposure or white-balance path assigning locked focus. All
continuous-capable cameras already select continuousAutoFocus and unrestricted
focus range. However, RAW telephoto still used automatic face priority and its
subject-area callback reassigned the focus point and mode. RAW main did neither.

Changes: disable smooth AF explicitly when supported (its previous actual value
was not recorded, so this is not a confirmed cause); disable face priority on all
RAW lenses; make subject-area notifications diagnostic only for all lenses to
avoid interfering with a running continuous scan. Log smooth AF, range restriction,
exposure and ISO with each focus snapshot.

Validation: signed iOS device build succeeded; 53 simulator unit tests passed.
Device was unavailable at this audit. Near/far autofocus speed, clarity and RAW/HQ
1×/4× physical acceptance remain pending. Blackmagic's private configuration has
not been inspected and parity is not established.

### Full-frame focus region trial

The iOS 26 SDK exposes focusRectOfInterest. Its documentation explicitly defines
CGRect(0, 0, 1, 1) as using the entire field of view to determine focus. Merely
omitting focusPointOfInterest does not enable this: its default is the center.
This trial was removed before acceptance: a full-frame region can prefer a distant
high-contrast background over the user's central near subject, and no optical
device test was available. The app retains its centered focus point, continuous
AF and RAW face-priority workaround. Focus diagnostics still record the actual
point and rectangle so later device tests can compare them.
Reference: https://developer.apple.com/documentation/avfoundation/avcapturedevice/focusrectofinterest

The full-frame trial compiled, but was never optically verified or accepted
for delivery.

## 2026-10-12 — RAW main-camera focus trigger diagnosis

On iPhone 17 Pro, the installed continuous-only build 1.0(2) recorded 240 RAW HQ
1× focus observations over 72 seconds. It received 95 subject-area notifications,
but `isAdjustingFocus` was always false and `lensPosition` stayed at 0.372549.
The selected 4224×2240/60 format used contrast AF and supported both single and
continuous focus. RAW frame delivery continued at about 60 fps. These readings
establish that the app requested continuous AF without an observed lens scan;
they do not identify Apple's internal reason for the idle state.

The prior user-accepted build had also initiated single-shot acquisitions, so
its success did not establish that continuous AF alone worked. Restored the
single-shot acquisition for RAW/RAW HQ physical main cameras when configured
and when the subject-area notification arrives. It returns to continuous AF
after the scan, with a timeout and a generation token for lens changes. The
implementation checks AF mode support and does not branch on iPhone model.

Signed device build succeeded; installed on iPhone 17 Pro as sequence 15748.
The first new trace observed three acquisitions and three returns to continuous
AF, with lens position changing from 0 to about 0.72. That trial selected an
Open Gate 4224×3024/60 format, whereas the stalled trace used 4224×2240/60;
the format difference limits a strict A/B claim. The user reports that visual
refocus still requires shaking the phone. The subsequent trace shows scans
when subject-area changes are delivered, but notifications do not reliably
arrive for the intended near/far change. An apparent 30 fps improvement was
not sufficient; the last device capability snapshot was 24 fps. Exposure was
about 1/500 second throughout, with ISO sometimes above 5000. The next
controlled check is a longer maximum exposure at 60 fps.

Existing 53 unit tests passed. Simulator UI tests that require a real camera
were inadvertently included in an initial broad test run and failed to reach
the ready camera state; the unit-only rerun passed. Optical focus acceptance
remains open.

### Controlled follow-up on iPhone 17 Pro / iOS 26.0.1

The controlled trials selected the same physical 1× RAW sensor format
(4224×2240 at 60 fps, format index 65), kept the application-triggered
reacquire path off, and requested `continuousAutoFocus`. With native full-size
Bayer output, a 87.5-second steady-state trace recorded 36 subject-area
notifications, changing exposure and ISO, but no focus adjustment and a fixed
`lensPosition` of 0.705882. With a single preview-sized 2112×1120 proxy output
on the same sensor format, a 38.2-second trace recorded 57 notifications and
again no lens movement. The user could not obtain reliable near focus without
moving the phone. The selected 1× RAW format and an alternate 4224×2240/60 RAW
format both failed the visual near/far check. Changing maximum exposure did not
restore the expected refocus behavior. This separates the autofocus stall from
frame delivery and automatic exposure, which both continued to operate.
An Open Gate 4224×3024/60 continuous-only trace likewise held the lens at
0.7451 for 34.9 seconds through ten subject-area notifications. The behavior
is not confined to format index 65.
In a same-trial RAW HQ comparison, the 4× camera showed 19 distinct lens
positions over 21.5 seconds, whereas the following 1× segment stayed at
0.705882 for 10.95 seconds despite 59 subject-area notifications and ISO
changing from 87 to 412. This supports a main-camera RAW-specific failure
mode; it does not establish the behavior of every iPhone model or iOS version.

The 1× camera enumerated three RAW-capable formats: 4224×2240 up to 60 fps,
4224×2240 up to 120 fps, and 4224×3024 up to 60 fps. All report
`AVCaptureAutoFocusSystemContrastDetection` (value 1). A HEVC 3840×2160/60
format reports phase detection (value 2). `autoFocusSystem` is a read-only
format property; the application cannot directly select an AF algorithm.

The mode scanner de-duplicates formats by resolution and frame rate, keeping
the first format. This hides format 66 behind format 65 at 4224×2240/60.
The policy is a future-device selection risk, but does not explain this
reproduction: both formats report contrast AF, and a forced format-66 preview
still failed the user's static near/far check. Format 66 also offered only
`aprn` as a MOV writer codec in this test, whereas format 65 offered both
`aprn` and `aprh`. Any later format ranking must preserve codec eligibility
before preferring an AF system. Simply exposing the duplicate would not
change the current automatic selection.

A single-shot `autoFocus` request on the original RAW format caused a real
lens scan at configuration, so the lens can move in that format. That trace
did not test whether a later near target would be acquired. The previous optically
successful build also used application-triggered single-shot AF; it was not
evidence that continuous AF alone worked. Subject-area notifications do not
reliably coincide with the user's static near/far changes, so that fallback
does not yet satisfy automatic near/far refocus. Do not describe the issue as
resolved. Frequent subject-area notifications can also cause repeated
single-shot scans; the visual check so far reported no visible pumping, but
recording-time stability and power cost remain unmeasured. A narrower center
focus rectangle was tried, but the focus-mode
setter reset its API readback, so that trial does not conclusively evaluate
hardware ROI behavior.
The available HEVC focus trace does not cover the same 1× lens, and the old
face-driven comparison also changed the application's single-shot policy;
neither supplies an isolated same-format A/B result.

An independent [iPhone 17 Pro ProRes RAW 60 fps report](https://www.youtube.com/watch?v=7jNgXcbJPDQ)
published on 2025-09-22 describes difficult autofocus at 24 mm, matching
the camera, codec and frame rate here. The video description is corroborating
user evidence, not an Apple acknowledgment. Apple's published
[iOS 26 update notes](https://support.apple.com/en-us/123075) do not identify
this autofocus issue or a fix. The evidence points to the iOS 26 RAW
continuous-AF path on this configuration, but does not isolate a specific
internal defect or establish behavior on later iOS versions.

A diagnostic second, preview-sized output was accepted concurrently with the
full RAW output at 60 fps. Its recording reliability, energy cost and focus
trigger quality were not validated; it is not a release-ready fallback.
The diagnostic launch flags, extra output and writer-capability bypass were
removed before restoring the app on the device.

The cleaned build was installed on the iPhone 17 Pro as sequence 15836 and
launched without diagnostic arguments. Its capability snapshot retained both
RAW writer codecs, and its startup trace showed a single-shot scan followed
by restoration of continuous AF. The signed device build and all 53 simulator
unit tests passed. Static near/far optical acceptance and recording-time
focus stability remain open.

## 2026-10-12 — MovieFileOutput comparison on iPhone 17 Pro

The standalone RAWFocusTest visibly refocused at `aprn` / physical 1× / RAW
format 69 (4224×3024) / 30 fps. GyroCine was changed to a temporary
`AVCaptureMovieFileOutput` diagnostic path with a live lens-position readout.
The IMU-to-MOV post-process is bypassed in this path. Without an external SSD,
RAW recording and recorded-image sharpness were not tested.

GyroCine initially configured only 1× RAW with a minimal capture graph. Its
continuous-AF mode read back as 2, yet after lens changes the user sometimes
observed blur and a fixed lens position. One trace held 1× at 0.541 for about
55 seconds; another held 0.553 for about 11 seconds after returning from 4×.
Moving the 1× white-balance lock to after session start, locking by mode only,
then omitting it did not consistently restore AF. Keeping the session and
MovieFileOutput running across RAW lens switches also failed. Removing RAW
preview rotation/stabilization overrides did not prevent intermittent failure.
Applying the RAW format after session start sometimes worked, but a later
cold-boot/switch trial failed. Setting the movie codec in the same session
configuration transaction as RAW format 69 also did not suffice by itself.

The current diagnostic build applies the minimal RAW graph to all RAW lenses:
it adds the movie output before selecting each RAW format, selects format and
codec together after starting the session, and skips extra audio, white-balance,
exposure, focus and movie-connection setters during RAW configuration. The user
reported near/far refocus after repeated lens switches and again after a true
iPhone power cycle. The latter trace began at about 30 seconds of system uptime;
multiple 1× segments after lens changes had changing lens positions. This is
promising preview evidence, not an isolated cause: several 4×/0.5× settings
changed together, and earlier variants also passed briefly before failing.

Evidence: `docs/device-evidence/raw-af-2026-10-12/` contains a stalled
comparison trace and the current cold-boot trace/capability snapshot. Before
shipping, restore and validate RAW audio, requested exposure/white balance,
SSD recording, IMU embedding, MOV playback, and autofocus during recording.
