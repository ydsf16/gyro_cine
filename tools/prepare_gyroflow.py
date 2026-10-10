#!/usr/bin/env python3
"""Explicit desktop compatibility input; leaves official JSONL and original IMU untouched.

GCSV is used solely to let Gyroflow perform offline sync without interpreting
unknown protobuf hardware readout times as zero. Gyroscope only: no inferred
accelerometer sign/orientation or manufactured hardware timestamps.
"""
import argparse
import json
import math
import statistics
from pathlib import Path


def prepare(folder: Path, output: Path, orientation: str) -> dict:
    if len(orientation) != 3 or sorted(orientation.upper()) != ["X", "Y", "Z"]:
        raise ValueError("orientation must be a signed permutation of XYZ")
    if output.exists():
        raise ValueError("output directory already exists; choose a fresh directory")
    diagnostics = json.loads((folder / "diagnostics.json").read_text())
    first = diagnostics["clock"]["firstVideoPTSSeconds"]
    asset_first = diagnostics["firstVideoPTSSeconds"]
    events = [json.loads(line) for line in (folder / "imu_raw.jsonl").read_text().splitlines() if line]
    gyro = [e for e in events if e["kind"] == "gyro"]
    if not gyro or not all(math.isfinite(e[k]) for e in gyro for k in ("timestamp", "x", "y", "z")):
        raise ValueError("missing or nonfinite gyro samples")
    if any(b["timestamp"] <= a["timestamp"] for a, b in zip(gyro, gyro[1:])):
        raise ValueError("gyro samples must be strictly increasing")
    output.mkdir(parents=True)
    gcsv = output / "clip.gcsv"
    with gcsv.open("w") as f:
        f.write("GYROFLOW IMU LOG\nversion,1.3\nid,RawMotionRecorder-offline\n")
        f.write(f"orientation,{orientation}\n")
        f.write("note,Provisional host clock mapping; offline sync required; hardware readout unknown\n")
        f.write("tscale,1\ngscale,1\nt,gx,gy,gz\n")
        for e in gyro:
            t = e["timestamp"] - first + asset_first
            f.write(",".join(format(v, ".17g") for v in (t, e["x"], e["y"], e["z"])) + "\n")
    report = {
        "sourceFolder": str(folder.resolve()), "gyroCount": len(gyro),
        "units": {"timestamp": "seconds", "gyro": "rad/s"},
        "orientationCandidate": orientation, "axisCalibrationVerified": False,
        "clockMapping": "CoreMotion timestamp - source first video PTS + asset first PTS",
        "hardwareReadoutKnown": False, "requiresOfflineSync": True,
        "accelerometerIncluded": False,
        "reason": "Native protobuf reader treats omitted hardware frame timestamps as zero. This separate GCSV input avoids invalid per-frame offsets; official clip.jsonl is preserved.",
    }
    evidence = folder / "video_samples.jsonl"
    if evidence.exists():
        rows = [json.loads(line) for line in evidence.read_text().splitlines() if line]
        matrices = [r.get("cameraIntrinsicMatrix") for r in rows]
        if matrices and all(k and len(k) == 9 and all(math.isfinite(v) for v in k) for k in matrices):
            k = [statistics.median(m[i] for m in matrices) for i in range(9)]
            w, h = diagnostics["actualWidth"], diagnostics["actualHeight"]
            profile = {
                "name": "RawMotion API intrinsics (distortion uncalibrated)",
                "calib_dimension": {"w": w, "h": h}, "orig_dimension": {"w": w, "h": h},
                "calibrator_version": "RawMotion-API-K-unvalidated-v1", "camera_brand": "Apple",
                "fps": diagnostics["measuredFrameRate"], "input_horizontal_stretch": 1.0,
                "input_vertical_stretch": 1.0, "distortion_model": "opencv_standard",
                "fisheye_params": {"camera_matrix": [k[:3], k[3:6], k[6:]], "distortion_coeffs": [0]*8}
            }
            (output / "api_intrinsics_candidate.json").write_text(json.dumps(profile, indent=2) + "\n")
            report["lensCandidate"] = {
                "source": "Median API attachment K in native output image coordinates",
                "framesWithK": len(matrices), "lensDistortionCalibrated": False,
                "zeroDistortionAssumption": "Explicit desktop PoC model only; NOT measured distortion and NOT written to official protobuf",
                "focalXRangePx": [min(m[0] for m in matrices), max(m[0] for m in matrices)]
            }
    (output / "preparation.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("recording_dir", type=Path)
    p.add_argument("--output", required=True, type=Path)
    p.add_argument("--orientation", required=True, help="Explicit candidate, e.g. XYZ; must be physically validated")
    a = p.parse_args()
    print(json.dumps(prepare(a.recording_dir, a.output, a.orientation), indent=2))


if __name__ == "__main__":
    main()
