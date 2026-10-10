# Gyroflow schema pin

- Source: `AdrianEddy/telemetry-parser/src/gyroflow/gyroflow.proto`
- Commit: `8bd825db33700c4d4472fae61eada27a65aea7a8`
- Downloaded: 2026-10-10
- SHA-256: `49c4dc1b6195ffa41ce6610ede3753e79e12b4f4a8042458f09eaf993b3ee8ae`
- Runtime validator: Python `protobuf==6.33.0`; generated `tools/gyroflow_pb2.py` via `grpcio-tools==1.76.0`.
- iOS encoder: typed Swift `Encodable` fields limited to names/types in this pinned schema. Python validator parses each line using the generated official descriptor and rejects unknown fields.

Reference: https://github.com/AdrianEddy/telemetry-parser/blob/8bd825db33700c4d4472fae61eada27a65aea7a8/src/gyroflow/gyroflow.proto
