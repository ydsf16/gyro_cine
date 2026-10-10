#!/usr/bin/env python3
"""Validate an M1 recording against the pinned official Gyroflow protobuf."""
import argparse
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path

from google.protobuf.descriptor import FieldDescriptor
from google.protobuf.json_format import ParseDict, ParseError
import gyroflow_pb2


NUMERIC_TYPES = {
    FieldDescriptor.TYPE_DOUBLE, FieldDescriptor.TYPE_FLOAT,
    FieldDescriptor.TYPE_INT32, FieldDescriptor.TYPE_INT64,
    FieldDescriptor.TYPE_UINT32, FieldDescriptor.TYPE_UINT64,
    FieldDescriptor.TYPE_SINT32, FieldDescriptor.TYPE_SINT64,
    FieldDescriptor.TYPE_FIXED32, FieldDescriptor.TYPE_FIXED64,
    FieldDescriptor.TYPE_SFIXED32, FieldDescriptor.TYPE_SFIXED64,
}


def check_numeric_types(value, descriptor, where, errors):
    for key, item in value.items():
        field = next((f for f in descriptor.fields if f.json_name == key or f.name == key), None)
        if field is None:
            continue  # ParseDict below reports unknown fields.
        items = item if field.is_repeated else [item]
        for child in items:
            if field.type in NUMERIC_TYPES and (type(child) not in (int, float) or not math.isfinite(child)):
                errors.append(f"{where}.{key}: expected finite JSON Number")
            elif field.type == FieldDescriptor.TYPE_MESSAGE and isinstance(child, dict):
                check_numeric_types(child, field.message_type, f"{where}.{key}", errors)


def validate(folder: Path) -> dict:
    errors = []
    movie = folder / "clip.mov"
    sidecar = folder / "clip.jsonl"
    raw = folder / "imu_raw.jsonl"
    diagnostics = folder / "diagnostics.json"
    for path in (movie, sidecar, raw, diagnostics):
        if not path.is_file() or path.stat().st_size == 0:
            errors.append(f"missing or empty: {path.name}")
    if errors:
        return {"pass": False, "errors": errors}

    metadata = json.loads(diagnostics.read_text(encoding="utf-8"))
    parsed = []
    sample_timestamps = []
    for line_number, line in enumerate(sidecar.read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        value = json.loads(line)
        check_numeric_types(value, gyroflow_pb2.Main.DESCRIPTOR, f"line {line_number}", errors)
        if "frame" not in value:
            errors.append(f"line {line_number}: missing frame")
            continue
        frame = value["frame"]
        if type(frame.get("frameNumber")) is not int:
            errors.append(f"line {line_number}: frameNumber is not JSON integer")
        for imu in frame.get("imu", []):
            if type(imu.get("sampleTimestampUs")) in (int, float):
                sample_timestamps.append(imu["sampleTimestampUs"])
        try:
            parsed.append(ParseDict(value, gyroflow_pb2.Main(), ignore_unknown_fields=False))
        except ParseError as exc:
            errors.append(f"line {line_number}: protobuf parse failed: {exc}")

    if not parsed:
        errors.append("no protobuf messages")
    else:
        first = parsed[0]
        if first.magic_string != "GyroflowProtobuf" or first.protocol_version != 1 or not first.HasField("header"):
            errors.append("invalid first Main header/version")
        if first.header.clip.file_frame_rate <= 0:
            errors.append("missing fileFrameRate")
        for index, message in enumerate(parsed, 1):
            if not message.HasField("frame") or message.frame.frame_number != index:
                errors.append(f"frameNumber mismatch at line {index}")
            if index > 1 and message.HasField("header"):
                errors.append(f"unexpected header at line {index}")
        if metadata.get("actualFrameCount") != len(parsed):
            errors.append("diagnostic frame count differs from JSONL line count")
        if metadata.get("status") != "completed_unverified_on_device":
            errors.append("recording status is not completed")

    raw_events = [json.loads(line) for line in raw.read_text(encoding="utf-8").splitlines() if line]
    if len(raw_events) != len(sample_timestamps):
        errors.append("raw IMU event count differs from sidecar sample count")
    if any(b < a for a, b in zip(sample_timestamps, sample_timestamps[1:])):
        errors.append("IMU sample timestamps decrease")
    for kind in ("gyro", "accel"):
        timestamps = [event["timestamp"] for event in raw_events if event.get("kind") == kind]
        if not timestamps:
            errors.append(f"no {kind} events")
        if any(b <= a for a, b in zip(timestamps, timestamps[1:])):
            errors.append(f"{kind} timestamps are not strictly increasing")

    probe = subprocess.run(
        ["ffprobe", "-v", "error", "-count_frames", "-show_entries",
         "stream=codec_name,codec_tag_string,width,height,nb_read_frames", "-of", "json", str(movie)],
        capture_output=True, text=True, check=False,
    )
    streams = json.loads(probe.stdout).get("streams", []) if probe.returncode == 0 else []
    video = next((stream for stream in streams if stream.get("codec_name") == "hevc"), None)
    if not video:
        errors.append("ffprobe did not identify an HEVC video stream")
    elif int(video.get("nb_read_frames", -1)) != len(parsed):
        errors.append("MOV decoded frame count differs from JSONL")
    intervals = [b - a for a, b in zip(sample_timestamps, sample_timestamps[1:])]
    return {
        "pass": not errors,
        "errors": errors,
        "movieVideo": video,
        "frameCount": len(parsed),
        "imuEventCount": len(raw_events),
        "imuIntervalMedianUs": statistics.median(intervals) if intervals else None,
        "diagnostics": metadata,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("recording_dir", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    result = validate(args.recording_dir)
    encoded = json.dumps(result, indent=2, ensure_ascii=False)
    if args.report:
        args.report.write_text(encoded + "\n", encoding="utf-8")
    print(encoded)
    return 0 if result["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
