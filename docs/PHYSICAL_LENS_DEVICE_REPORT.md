> Latest correction: [clock origins, RoamShot comparison and cropping](TIMING_AND_CROP_REPORT.md). GCSV projects now restore the first-sample origin; earlier empty-offset statements describe the previous implementation.

# iPhone 16 physical lens acceptance — 2026-10-10

Device: YJJY, iPhone16 / iOS18.2.1. App built and installed through Xcode on the connected device. Main 1x and ultrawide 0.5x were discovered; no physical telephoto button was shown.

## Device and data results

| Capture | Lens | Encoded frames | Gyro / accel samples | Duration | Maximum source-to-MOV PTS residual |
| --- | --- | --- | --- | --- | --- |
| recording_20261010_205107 | Main 1x | 675 | 2262 / 2262 | 22.500 s | 0.832798 ms |
| recording_20261010_205136 | Ultrawide 0.5x | 674 | 2258 / 2258 | 22.468 s | 0.833548 ms |
| recording_20261010_205636 | Ultrawide 0.5x retry | 674 | 2256 / 2255 | 22.468 s | 0.832414 ms |

Each test waits 20 seconds after asserting Recording; UI start/stop overhead accounts for the approximately 22.5-second files. No long recording was performed.

PASS:
- 8/8 unit tests on device; both initial per-lens recording UI tests plus ultrawide retry passed. Selection buttons disabled during recording.
- Physical device IDs in diagnostics match the requested lenses. Per-frame API K available on every frame; EIS off. Median fx: main 2879.895 px, first ultra 1455.936 px, retry ultra 1463.080 px. Lens profiles and embedded project profiles agree.
- Four files generated per recording. GCSV preserves every actual gyro timestamp/vector with seconds/rad/s units. No artificial per-frame synchronization offsets. Raw accel remains separately preserved.
- Stable Gyroflow 1.6.3 loads main and ultra projects from desktop copies, resolves relocated video/GCSV, and reads 2262/2258 gyro samples respectively.
- Preview screenshots show 0.5x/1x labels and selected highlights; retry screenshot shows a wide view of the room. Initial ultra capture was textureless, so its visual quality is not accepted.

A source-to-MOV PTS residual below 1 ms validates the video timestamp mapping only; it does not establish optical-to-gyro alignment within 1 ms.

## Share regression and repair

Original ShareLink dismissed the library without retaining a usable activity sheet. Replaced it with UIActivityViewController presented by a dedicated sheet and borderless row button. The next test revealed a test-locator error (Save to Files is a Cell, not Button); locator corrected.

Final device test PASS: activity sheet present, title `4个文稿`, Save to Files available. Screenshot saved under `artifacts/device_runs/physical_lenses/share_screenshots/`. This verifies share-sheet population; an external AirDrop/Files destination was not selected. Desktop analysis used devicectl copy, not a claimed external share delivery.

## Gyroflow 1.6.3 offline synchronization

- Main: offsets -297.23 / -11.22 / 30.86 ms. Inconsistent; synchronization/quality FAIL acceptance. Log includes insufficient optical-feature/OpenCV failures. No stable offset is claimed from this clip.
- Ultra retry: offsets 46.73 / 40.99 / 44.82 ms (span 5.74 ms), project saved. Stabilized video rendered by stable 1.6.3. These are clip-specific offline estimates, not measured hardware latency.
- HEVC seeking warnings (POC/RPS/NALU) and bookmark warnings remain in logs. Do not infer full decoder or GUI bookmark acceptance from CLI exit code.
- Lens profiles remain API-K estimates with uncalibrated zero distortion. Per-lens distortion/axis calibration and visual-quality acceptance remain pending. Rolling shutter correction remains deferred.

## Stabilized output checks

- Actual rendered output: H.264 3840x2160, 674 frames, AAC 48 kHz. CLI requested 1920x1080 but this build retained project 4K dimensions; actual probe is authoritative. Full ffprobe frame decode succeeded.
- Optical motion comparison over 646 identical valid adjacent frame pairs: angular step-change RMS ratio 0.422 (about 58% lower), center step-change RMS ratio 0.546 (about 45% lower). This supports improvement on this ultra clip only. Intentional movement, crop, parallax and OIS affect the metric; it does not replace axis/calibration/visual acceptance.
- All three recordings contain audio, no duplicate gyro/accel timestamps, approximately 99.73 Hz sampling and maximum sensor gap about 10.029 ms.

## Evidence and reproduction

- `artifacts/test_logs/physical_lenses_device.log`: initial 8 unit + 2 capture tests.
- `artifacts/test_logs/physical_ultrawide_retry.log`: repeat capture after user readiness.
- `artifacts/test_logs/physical_share_sheet_final.log`: latest 8 unit + share UI test, all passed.
- `artifacts/device_runs/physical_lenses/*_validation.json`: raw/export/video comparison.
- `artifacts/test_logs/physical_main_gyroflow.log`, `physical_ultrawide_gyroflow.log`: stable reader results.
- `artifacts/test_logs/physical_main_autosync.log`, `physical_ultrawide_retry_autosync.log`: actual synchronization attempts.
- `artifacts/device_runs/physical_lenses/ultrawide_retry_sync/`: saved project, stabilized video and output validation.

Repeat: connect/unlock, aim at bright textured scene, choose a lens, record 20 seconds with slow rotation, export files together, open clip.gyroflow in 1.6.3, synchronize and save separately for each clip. Validate a copied recording with `python3 tools/validate_legacy_recording.py <recording_folder>`.

M1 remains incomplete because main synchronization and lens/axis quality acceptance are unresolved; ProRes RAW has not started.
