# SSD MOV synchronization compatibility — 2026-10-11

## Evidence

The user's screenshot identifies the failure stage as `同步追加内容到磁盘` with Cocoa 512 wrapping POSIX 22 (`EINVAL`). The failure occurs after metadata writes and before replacing the original MOV index. This identifies the failing API operation, but does not establish the underlying filesystem/driver cause.

## Change

All MOV append transaction sync points (recovery journal, appended data, index commit, rollback) retain Foundation synchronization first. Only nested POSIX EINVAL/ENOTSUP/ENOSYS triggers a standard descriptor `fsync` fallback. Interrupted fsync retries. Failure of the fallback remains fatal and includes the original error. EIO and other ordinary write failures are not ignored.

The original index remains intact until append synchronization and length/index readback succeed. Recovery journal and rollback remain in place. No entire-video copying is added. A successful fallback logs `GyroCine MOV sync: Foundation unsupported; POSIX fsync succeeded`.

## Acceptance

- Signed iOS build: passed (`/tmp/gyro-sync-build.log`).
- Automated tests: 47 passed, 0 failures (`/tmp/gyro-sync-tests.log`), including unsupported-sync fallback, interrupted retry, failure propagation, append integrity and rollback tests.
- iPhone + external SSD: pending. The device was unavailable at build time. This is a compatibility fix awaiting reproduction on the affected filesystem; if plain fsync also returns EINVAL, recording will still be retained rather than silently claimed successful.

## Device verification

1. Install the updated build, attach and authorize the SSD.
2. Select the previously failing lens/RAW mode and Sony MOV output, record 20 seconds, stop.
3. Check that finalization completes and the MOV imports video + motion + lens into Gyroflow.
4. Inspect synchronization/finalization logs. Confirm no recovery journal remains after a successful transaction. Repeat with protobuf MOV and internal HEVC for the other output/storage path.
