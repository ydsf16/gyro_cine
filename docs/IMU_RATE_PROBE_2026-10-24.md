# IMU sampling rate probe — 2026-10-24

Debug launch argument: `--imu-rate-probe`. Each requested rate runs for 6 seconds on the device. The report is saved to `Documents/imu-rate-probe.json`. Production capture remains at 100 Hz.

| Device | Requested | Accepted interval | Gyro observed | Accel observed | Median gap |
| --- | ---: | ---: | ---: | ---: | ---: |
| iPhone 16 | 100 Hz | 10 ms | 99.73 Hz | 99.73 Hz | 10.024 ms |
| iPhone 16 | 200 Hz | 10 ms | 99.76 Hz | 99.76 Hz | 10.024 ms |
| iPhone 16 | 400 Hz | 10 ms | 99.76 Hz | 99.76 Hz | 10.024 ms |
| iPhone 17 Pro | 100 Hz | 10 ms | 99.93 Hz | 99.96 Hz | 10.004 ms |
| iPhone 17 Pro | 200 Hz | 10 ms | 99.96 Hz | 99.96 Hz | 10.004 ms |
| iPhone 17 Pro | 400 Hz | 10 ms | 99.95 Hz | 99.95 Hz | 10.005 ms |

These devices cap Core Motion delivery at about 100 Hz for this app. Increasing the requested rate does not add samples. Validate other devices from sample timestamps before changing the production interval.
