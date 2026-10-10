# Task 2 report — 2026-10-10

**Code candidate complete; Gyroflow acceptance PENDING.** Final MOV is parsed with `AVAssetReader`; actual encoded frame samples drive 1..N sidecar messages. Fixed schema is `gyroflow.proto` commit `8bd825db33700c4d4472fae61eada27a65aea7a8`. Unknown readout, OIS, lens and axis-calibration fields are omitted. Irregular frame spacing fails finalization and preserves raw files.

- Simulator XCTest: 3/3 passed at 19:18 CST.
- Desktop validator tests: 3/3 passed at 19:18 CST using a synthetic HEVC MOV; covered valid protobuf/MOV count, quoted numeric rejection and bad frame sequence rejection.
- Real iPhone JSONL, telemetry-parser conversion, Gyroflow auto-load, motion sync and stabilized export: pending. No PASS claim. See `M1_REPORT.md`.
