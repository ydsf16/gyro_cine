# Camera controls QA — 2026-10-17

## Scope

- Default physical wide camera (1×).
- Friendly internal-files RAW storage error with Settings action.
- Exposure type labels Speed / Angle; angle ruler also shows exposure duration.
- Device-limited shutter range, up to one frame duration (360°), preserving selected FPS.
- Non-RAW WB Auto-L / Auto / Manual. Auto-L locks before capture warmup and restores automatic WB after stop/failure.
- Sixth top control for exposure compensation, using the device EV range. Disabled during fully manual exposure.
- Optional ruler haptics, discrete ISO/shutter/angle stops and snapping.
- Preserve requested manual ISO/time/angle/WB across configuration changes; clamp actual values to hardware support. Changing ISO retains active shutter angle and uses current FPS.

## Device and method

- Connected iPhone 18 Pro Max (iPhone19,7), iOS 27.0.1.
- Xcode 27.1, Release build; XCUITest directly on device, no iPhone Mirroring.
- Preserve existing Media. Test recordings identified by before/after inventory difference, then deleted through Media UI.
- XCTest waits about 60 seconds for some SwiftUI menu animation completions. This is test-driver delay; report actual assertions separately.

## Evidence

- `/tmp/gyrocine-controls-1.xcresult`, `/tmp/gyrocine-controls-1.log`.
- 21 DefaultsAndOrientationTests passed, including discrete stops/device limits and manual exposure clamping.
- `testControlsAngleEVAndHaptics`: passed; screenshot attachments include angle/time ruler and six controls. EV changed to +4.0 within device range.
- `testControlsDefaultLensAndRAWStoragePrompt`: passed; 1× default and dedicated storage/SSD error plus Settings action verified.
- First run: all 25 tests passed (21 unit + 4 UI).
- Manual exposure: 1× → 0.5× → 1× and 30 → 60 → 30 fps preserve requested 0.001 s / ISO 200. Sensor line-time quantization briefly reports 1/1005 vs 1/1001; final returned values match. Subsequent assertions allow 1% reciprocal-time tolerance, not an arbitrary mode reset.
- WB: three H.265 recordings completed, each with six recording-health samples. Auto-L and Manual mode=0 with identical gains throughout; Auto mode=2. Auto-L logs lock before capture and mode=2 restoration after stop. Logs copied to `/tmp/gyrocine-controls-logs4` and checked with assertions.
- Screenshots exported to `/tmp/controls-shots1`: dual angle/time labels and WB three-way selector visually inspected, no overlap.
- Follow-up `/tmp/gyrocine-controls-2.xcresult`: manual exposure + WB preservation and all three WB recordings passed. Requested ISO 320 / 0.001 s and ~6900 K survived lens/FPS changes. The angle test confirmed 180° at 30 fps (0.016666 s), then 60 fps (0.008333 s), including subsequent ISO changes.
- That run's final haptic assertion failed because XCTest tapped the SwiftUI row label rather than the right-hand switch. Test corrected to use the observed switch element's right side; follow-up `/tmp/gyrocine-controls-3.xcresult` checks the actual toggle state and audio-session permission.
- AVAudioSession defaults to suppressing haptics while audio input is active. The preference now explicitly calls `setAllowHapticsAndSystemSoundsDuringRecording` on the camera queue, with requested and returned state logged.
- Durable local evidence: `artifacts/controls-20261017/` (ignored by Git).

## Final result

- 21 unit tests and five distinct device UI scenarios accepted across the runs. Run 3 passed after correcting the switch hit target.
- Final log assertions passed: Auto-L 6, Auto 5, Manual 6 health samples in the latest recordings; locked-mode gains constant. 26 angle/ISO intent samples all match `0.5 / FPS` at 180° within 2 microseconds.
- At 02:12:07 UTC, haptic log confirms `requested=true`, `allowedWithAudioInput=true`; no haptic configuration error.
- Six newly recorded short clips were removed through the test's inventory-difference cleanup. Existing `IMG_0014.mov` (341.5 MB, predates this test run) remains untouched.
- Final ordinary Release build succeeded (`release-build.log`), installed separately from the test runner.
- No commit, remote push, or TestFlight upload performed for this request.

## Boundaries

### Haptic regression follow-up

- Default was still false and prior test used `-rulerHaptics YES`, masking normal launch behavior. Both UI defaults are now true; one-time preference migration enables existing installs, after which explicit user changes persist.
- UISelectionFeedbackGenerator now uses `init(view:)` attached to the actual ruler. Every drag/accessibility adjustment reapplies the requested audio-session haptic permission on the camera queue.
- Removed the launch override from the startup/all-rulers test and asserted the real Settings switch on both launches. Early runs could not reach camera readiness; after normal launch confirmed a working preview, the rerun passed (`/tmp/gyrocine-haptics-default3.xcresult`, 61.407 s).
- Seven audio-session log checks (startup + all five drags + relaunch) returned requested=true and allowedWithAudioInput=true. Physical tactile feedback still requires user confirmation; these checks do not measure vibration.

### Startup-default follow-up

- Each fresh camera-manager launch now starts H.265 / physical 1× / 3840×2160 / 60 fps (nearest supported configuration on limited hardware), internal files, angle display, A-Max 180° (1/120 s at 60 fps), automatic ISO/WB and continuous AF, EV zero. Saved capture choices no longer override fresh launch. Lens changes within the session retain current preferences.
- Ruler haptics preference remains persistent and shared by shutter/angle, ISO, WB, focus and EV. First tick and accessibility increments now also trigger feedback when enabled; disabled controls do not.
- `testStartupDefaultsAndAllRulers` passed on device: changed all five rulers and lens, relaunched and checked default settings/UI. Log confirms H.265/60, exposure mode=2, WB Auto/mode=2, continuous AF, and haptics allowed with audio input. `/tmp/gyrocine-startup-defaults.xcresult`, `/tmp/gyrocine-startup-logs`. Tactile strength remains a subjective manual check.

Latest requested ranges (supersede earlier UI ranges): manual WB 2500–10000 K; EV −6…+6 intersected with hardware limits; ISO hardware range; shutter 1/8000 s through 1/FPS intersected with hardware limits. Angle mode uses the same time bounds. Applied to ruler, camera writes and configuration restoration. Release build checked; no new physical range-endpoint test in this follow-up.

- Haptic toggle and gesture path are automatable; subjective tactile strength needs a person holding the phone.
- No claim of cross-device physical validation from this one-device run.
- Video pipeline and RAW autofocus preparation remain on existing implementation; no re-encoding introduced.

## RAW white-balance regression correction

- User reported RAW WB had become unlockable. Shared WB preference application and the legacy A/M control permitted automatic WB in RAW preview.
- RAW/RAW HQ now override automatic WB preferences with locked WB immediately during configuration. Returning from recording/error keeps RAW locked. Automatic setters reject all RAW preview/recording requests.
- RAW UI shows a read-only lock indicator. Manual Kelvin/presets remain available. H.265 keeps Auto-L / Auto / Manual.
- Device log checks: both `aprn` and `aprh` configuration results (including 0.5× → 1×) report whiteBalanceMode=0. `/tmp/gyrocine-raw-wb-logs2`.
- XCUITest: `testRAWWhiteBalanceAlwaysLocked`, `/tmp/gyrocine-raw-wb-fix2.xcresult`; first run interrupted at menu selection, corrected helper uses observed option coordinates and verifies selection.
- This regression run checks preview/configuration and codec switching; it does not add another RAW recording test.
- Final rerun passed (233.970 s); returning to H.265 restores its three WB controls. Ordinary Release rebuild succeeded.
