# SSD / lens switch / writer backpressure — 2026-10-11

## Evidence
- User clip: Downloads/GyroCine_20261011_153131; original also on PortableSSD/DCIM. Underlying save error is NSPOSIXErrorDomain:22 (EINVAL), wrapped by NSCocoaErrorDomain:512. Writer completion 0.013s, archive 0.074s, MOV index scan 0.012s, embedded-export failure at total 0.879s. No capture-drop callbacks. Old logging cannot identify the failing syscall.
- Three copied device crash reports (15:35:17, 15:35:34, 15:37:46) all point to ShutterSetting.isSupported -> Array subscript, called from selectLens/supportedShutters. Changing lens left selectedMode holding the previous camera's format index.

## Changes
- Clear old selectedMode before assigning a new lens, resolve a compatible new mode before checking shutters. Guard shutter/ISO/exposure format indices.
- Stop capture and drain old sample callbacks before replacing device state. Clamp RAW white-balance gains. Restart autofocus acquisition then continuous AF after session setup.
- Add bounded FIFO for transient video writer backpressure (48 entries; copied-pixel pool separately capped around 768MB). Preserve arrival-time frame evidence. On stop, drain with a 5-second bound before finishing; no successful save if overflow/drain failure occurs.
- Stop requesting important-usage capacity during MOV metadata append; only ordinary free capacity is needed. This removes an unnecessary external-volume API call, but is not yet confirmed as the EINVAL cause.
- Include per-operation stage and compact nested error codes. Preserve original and rollback failures separately. Keep synchronization and recovery checks.

## Validation
- 44 simulator unit tests passed: /tmp/gyro-lens-queue-tests.log.
- Signed device test build succeeded. RAW physical-lens UI test: six 1x/0.5x round trips (12 transitions), each returned ready, no crash: /tmp/gyro-lens-device-test2.log.
- First UI test attempt failed because the lens bar overrides child accessibility identifiers; test selectors were corrected using observed visible labels, then rerun passed.
- Device capability readback: continuous autofocus supported=true, focusMode=2, activeVideoStabilizationMode=0. Does not establish optical sharpness.
- Mac copied the actual 1.6GB RAW file to a temporary folder on the user's SSD, appended synthetic metadata in 0.024s and removed the temporary copy. Original files unchanged. This validates Mac SSD I/O, not iOS authorization or export compatibility of synthetic data.
- New build reinstalled on iPhone 17 Pro. SSD was attached to Mac during testing, not phone.

## Still pending
- RAW Sony MOV save on iPhone with SSD attached: EINVAL resolution unconfirmed.
- Sustained RAW throughput/backpressure at 4K60; buffer cannot compensate indefinitely for insufficient encoder/disk throughput.
- Near/far autofocus sharpness after lens switches in bright textured scenes.
