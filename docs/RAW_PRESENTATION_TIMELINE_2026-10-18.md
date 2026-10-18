# RAW presentation timeline regression — 2026-10-18

## Scope

Only RAW presentation timing and its required capture/IMU correspondence change.
No changes to K values, exposure values or exposure-center convention, autofocus,
preview, encoder settings, H.265 capture, storage routing or buffer limits.
Existing media is not rewritten. No additional video encoding pass is introduced.

The user's C041 timing-table-only experiment reportedly improved its twitch metric
by about 93.5%. This motivates the change; it is not a measured result for this build
and does not establish that timebase precision itself caused the defect.

## Implementation

- Snapshot the configured RAW frame interval when constructing the writer.
- Use a 60,000-tick presentation scale (60 fps = exactly 1,000 ticks/frame).
- For each increasing capture PTS, round the elapsed capture interval to its
  number of frame slots. Advance by that many slots, not by delivered frame count.
  An absent capture therefore leaves a gap; no duplicate/interpolated video frame
  is inserted and the missing interval is not closed.
- Snapshot original capture PTS/K/exposure before creating the timing-only sample
  copy. Image data remains shared. Audio retains its original timestamps.
- Store MOV-relative presentation time beside real host capture time in the
  recovery sidecar. Match metadata by presentation time and keep the original
  capture values unchanged.
- The self-contained MOV `rmin` note includes `capture_first_frame_host_seconds`
  and one `capture_minus_presentation_seconds` entry per video frame. Together
  with MOV PTS these reconstruct the original host capture times.
- Sony IMU interpolation uses the inverse presentation→capture mapping. Proto
  IMU sample times use the corresponding capture→presentation mapping. Both
  mappings interpolate between real frame pairs, including across missing slots.
- Older sidecars without presentation times keep the original identity mapping.
  Incomplete RAW mappings fail packaging and retain original records.

## Evidence

- Debug and Release physical-device builds: PASS.
- Simulator `ExposureTimingTests`: 9 passed, 0 failed. Includes 18,000 continuous
  frames (five minutes), jitter rejection, retained missing slot, non-increasing
  source rejection, bidirectional capture/IMU correspondence, exact metadata/K/
  exposure retention, and decoding older sidecars.
- iPhone 18 Pro Max, 1×, RAW `aprn`, 4224×2240, 60 fps, dedicated storage:
  `UITEST_IMG_writer_445A3F1E-9749-4720-BB48-D442BCAF99AD.mov`.
  300 frames / 5.000000 seconds; `stts` exactly `[(300, 1000)]` at 60,000 Hz.
  Capture drops 0; missing presentation slots 0; peak retained video buffers 1.
- Final MOV: RAW video + stereo AAC + 300 Sony RTMD packets / 5 seconds.
  500 gyro and 500 accelerometer samples; 300 real K records; no estimated K.
  Original capture mapping has 300 entries, maximum difference about 2.056 ms.
- Full RAW video decode to a null sink: PASS (ffmpeg exit 0, empty error log).
- Local evidence: `/tmp/gyrocine-raw-presentation-audit.json`,
  `/tmp/gyrocine-raw-presentation-capture.log`,
  `/tmp/gyrocine-raw-presentation-tests-final.log`.

## Remaining validation

New moving-scene RAW footage must be compared in Gyroflow before claiming an
improvement in visible twitch/stabilization. The stationary five-second capture
proves timing and packaging, not optical synchronization or visual improvement.
Real-device loss was not induced in this run; missing-slot behavior is unit tested.
Long physical recordings and other RAW frame rates are outside this focused run.
