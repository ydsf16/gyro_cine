# RAW HQ lens matrix and responsiveness review — 2026-10-16

## Scope

Device: iPhone 18 Pro Max (iPhone19,7), iOS 27.0.1. Xcode/SDK 27.1.
Debug dedicated-storage AVAssetWriter RAW experiment, aprh, AAC, Sony embedded IMU and same-frame K. Approximately 10 seconds per supported configuration. No video re-encoding.

| Lens | Resolution | 30 fps | 60 fps | 120 fps |
| --- | --- | --- | --- | --- |
| 0.5× | 4224×2240 | Saved, 301 frames, 0 capture drops | Saved, 601 frames, 0 drops | Not advertised by device |
| 0.5× | 4224×3024 | Saved, 303 frames, 0 drops | Saved, 601 frames, 2 drops; three isolated retests 605/603/603 frames, 0 drops | Not advertised by device |
| 4× | 4224×2240 | Saved, 302 frames, 0 drops | Saved, 604 frames, 0 drops | Not advertised by device |
| 4× | 4224×3024 | Saved, 302 frames, 0 drops | Saved, 603 frames, 0 drops | Not advertised by device |

All eight supported matrix clips completed indexed movie/audio/IMU/K finalization checks. Saved does not imply optical stabilization or long-duration reliability. 0.5× Open Gate 60 still has an observed intermittent FrameWasLate event: maximum PTS gap 50.029 ms, writer peak buffer 1. Near that event camera queue probes were 0.8–2.7 ms and main probes below 5.7 ms; evidence does not establish the cause. Do not call it fixed based on three clean retests.

## WB readiness

An earlier HQ matrix failed at 0.5× Open Gate 30 because the white-balance completion never arrived despite live frames. The latest code retries on delivered frame counts, accepts valid FIFO completions, and supports readback confirmation after three attempts: locked mode, no adjustment, current in-use gains matching target within 0.01, valid/increasing PTS, eight consecutive matching frames. Readback is logged as a separate readiness source, not as the exact effective completion timestamp. Injecting loss of every completion successfully recorded 303 frames at Open Gate 60, zero capture drops, audio and IMU finalized. Fifteen-second preparation timeout invalidates the failed preview so a new recording can reprepare.

## Thread review / implemented changes

- Attach AVCaptureVideoPreviewLayer before requesting capture startup; configure/start on userInitiated camera queue.
- Move initial directory migration and log-file creation off SwiftUI initialization. Capture waits asynchronously for logger preparation.
- Eliminate main.sync from finalization eligibility; lifecycle observers snapshot state on main then send it to camera queue.
- Move expensive pending IMU completion to a separate utility queue, serialize completion, block recording/reconfiguration until finished.
- Cache storage capacity for SwiftUI rendering instead of querying dedicated storage inside the view body.
- Bound generated Media thumbnails to 246×174.
- DEBUG-only 20-second startup probes sample main/camera queue dispatch latency every 250 ms.

Across the latest twelve matrix launches the main probe maximum was approximately 21 ms, with no sample above 100 ms; camera startup/configuration waits reached approximately 489 ms. This excludes work before preview attachment and is sampled evidence, not proof all intermittent hangs are fixed. There is no measured pre-change baseline.

## GPU

Preview uses AVCaptureVideoPreviewLayer, without CPU image conversion or custom frame rendering. An eight-second Metal System Trace attached to GyroCine captured 4,635 GPU intervals attributed to the system compositor backboardd. Its potential-hangs table (threshold 100 ms) was empty. This establishes observed system-compositor GPU activity during this preview; it does not isolate camera-only GPU utilization or prove the RAW encoder hardware path. Counter Set was null; no utilization percentage is claimed.

## Build / evidence

Debug and Release builds passed; latest Debug installed. git diff --check passed.
Local raw logs/results: artifacts/prostorage-20261016/hq-responsive/.
Trace: /tmp/gyrocine-preview-metal-pid.trace.
Earlier failed HQ matrix: /tmp/gyrocine-hq-matrix/ (retain negative evidence).
Full-file decode and K verification results are recorded below when complete.

## Additional regression and storage cleanup

H265 4K60 MovieFileOutput smoke completed approximately 20 seconds, no delegate error, K callback health zero long gaps, IMU finalized. Initial automatic launch attempted REC during a system startup interruption and returned Camera session is not running; the system interruption ended about 180 ms later. Relaunch/retest succeeded. This initial auto-test startup race is retained in `gyrocine-responsive-hevc.log`; no claim all cold-start recording races have been eliminated.

User requested space cleanup. Deleted 30 explicitly named UITEST_ MOVs and matching sidecars: 82,821,883,098 bytes. Dedicated storage replenish reported 150,000,001,024 bytes available. IMG_0001 through IMG_0004 retained with identical sizes before/after. Two selected HQ source movies and logs were copied to the Mac before cleanup; full decode completed locally.

## Completed full-file checks

- 4× Open Gate HQ60: 603 video frames, aprh, AAC, rtmd; K PASS, maximum alignment 0.836331 ms; complete ffmpeg video+audio decode exit 0, empty error log.
- 0.5× Open Gate HQ60 isolated retest 3: 603 video frames; K PASS, maximum alignment 0.843689 ms; complete ffmpeg video+audio decode exit 0, empty error log.
- No re-encoded deliverable was produced: decode used a null sink. No Gyroflow optical stabilization or long-duration acceptance in this pass.
- App left running normally without test/cleanup/fault-injection launch flags.
