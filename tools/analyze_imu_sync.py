"""Estimate optical/embedded-gyro lag in a Sony MOV without changing the movie.

This is a diagnostic: translation from feature tracks is only an angular-motion
proxy. Confirm a proposed correction with repeated clips and Gyroflow Auto Sync.
"""

import argparse
import json
import struct
import subprocess
from pathlib import Path

import cv2
import numpy as np

from compare_mov_timing import boxes, child, uint


def samples(path, sensor="gyro"):
    base = {"gyro": 0xe435, "accel": 0xe445}[sensor]
    with path.open("rb") as f:
        size = path.stat().st_size
        pos = 0
        moov = None
        while pos < size:
            f.seek(pos)
            head = f.read(8)
            if len(head) != 8:
                break
            n = int.from_bytes(head[:4], "big")
            overhead = 8
            if n == 1:
                n = int.from_bytes(f.read(8), "big")
                overhead = 16
            if n == 0:
                n = size - pos
            if head[4:] == b"moov":
                moov = f.read(n - overhead)
            pos += n
        if moov is None:
            raise ValueError("MOV moov missing")
        for kind, track in boxes(moov):
            if kind != "trak":
                continue
            mdia = child(track, "mdia")
            stbl = child(child(mdia, "minf"), "stbl")
            stsd = child(stbl, "stsd")
            if stsd[12:16] != b"rtmd":
                continue
            mdhd = child(mdia, "mdhd")
            scale = uint(mdhd, 20 if mdhd[0] == 1 else 12)
            stts = child(stbl, "stts")
            durations = [delta / scale for i in range(uint(stts, 4))
                         for count, delta in [struct.unpack_from(">II", stts, 8 + 8 * i)]
                         for _ in range(count)]
            co64 = child(stbl, "co64")
            offsets = [int.from_bytes(co64[8 + 8 * i:16 + 8 * i], "big")
                       for i in range(uint(co64, 4))]
            stsz = child(stbl, "stsz")
            sizes = ([uint(stsz, 4)] * uint(stsz, 8) if uint(stsz, 4)
                     else [uint(stsz, 12 + 4 * i) for i in range(uint(stsz, 8))])
            if len(offsets) != len(sizes) or len(offsets) != len(durations):
                raise ValueError("Unexpected RTMD chunk layout")
            result = []
            for offset, length, delta in zip(offsets, sizes, durations):
                f.seek(offset)
                packet = f.read(length)
                tags = {}
                q = 28
                while q + 4 <= len(packet):
                    tag = int.from_bytes(packet[q:q + 2], "big")
                    amount = int.from_bytes(packet[q + 2:q + 4], "big")
                    q += 4
                    tags[tag] = packet[q:q + amount]
                    q += amount
                factor = struct.unpack(">f", tags[base + 4])[0]
                raw = tags[base + 6]
                count, vector_size = struct.unpack_from(">II", raw)
                if vector_size != 6 or len(raw) != 8 + count * 6:
                    raise ValueError("Invalid Sony gyro vector array")
                for index in range(count):
                    xyz = np.array(struct.unpack_from(">hhh", raw, 8 + index * 6), np.float64) / factor
                    result.append(xyz)
            # Match Gyroflow stable's Sony normalization for frame-grouped as
            # well as legacy one-vector packets. Exposure offsets remain separate.
            if not result:
                raise ValueError("Sony gyro track has no samples")
            times = np.arange(len(result)) * (sum(durations) / len(result))
            return np.column_stack((times, np.asarray(result)))
    raise ValueError("Sony RTMD gyro track missing")


def frame_pts(path):
    output = subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "frame=best_effort_timestamp_time", "-of", "json", str(path)
    ])
    values = [float(f["best_effort_timestamp_time"])
              for f in json.loads(output)["frames"]]
    return np.asarray(values)


def optical_rates(path, pts, width=960):
    capture = cv2.VideoCapture(str(path))
    if not capture.isOpened():
        raise ValueError("OpenCV cannot decode MOV")
    times, rates, qualities = [], [], []
    previous = None
    previous_points = None
    index = 0
    while True:
        okay, image = capture.read()
        if not okay:
            break
        scale = width / image.shape[1]
        gray = cv2.cvtColor(cv2.resize(image, (width, round(image.shape[0] * scale))), cv2.COLOR_BGR2GRAY)
        if previous is not None and index < len(pts):
            if previous_points is None or len(previous_points) < 80 or index % 15 == 0:
                previous_points = cv2.goodFeaturesToTrack(previous, maxCorners=350, qualityLevel=0.01,
                                                          minDistance=12)
            if previous_points is not None:
                next_points, valid, _ = cv2.calcOpticalFlowPyrLK(previous, gray, previous_points, None)
                if next_points is not None:
                    old = previous_points[valid.ravel() == 1]
                    new = next_points[valid.ravel() == 1]
                    matrix, inliers = cv2.estimateAffinePartial2D(old, new, method=cv2.RANSAC,
                                                                   ransacReprojThreshold=2.5)
                    if matrix is not None and len(old) > 25:
                        dt = pts[index] - pts[index - 1]
                        if dt > 0:
                            times.append((pts[index] + pts[index - 1]) / 2)
                            rates.append((matrix[0, 2] / dt, matrix[1, 2] / dt,
                                          np.arctan2(matrix[1, 0], matrix[0, 0]) / dt))
                            qualities.append(float(np.mean(inliers)))
                    previous_points = new.reshape(-1, 1, 2) if len(new) else None
        previous = gray
        index += 1
    capture.release()
    return np.asarray(times), np.asarray(rates), np.asarray(qualities), index


def estimate(path):
    gyro = samples(path)
    pts = frame_pts(path)
    times, rates, qualities, decoded = optical_rates(path, pts)
    if len(times) < 50:
        raise ValueError("Too few trackable frames")
    good = qualities >= 0.6
    times, rates = times[good], rates[good]
    lag_grid = np.arange(-0.150, 0.1501, 0.001)
    candidates = []
    for video_axis in (0, 1, 2):
        visual = rates[:, video_axis]
        visual = visual - np.median(visual)
        for gyro_axis in (1, 2, 3):
            for lag in lag_grid:
                # Positive lag means sampled gyro event occurs later than the
                # matched optical video motion in the MOV timeline.
                motion = np.interp(times + lag, gyro[:, 0], gyro[:, gyro_axis])
                if np.std(motion) < 1e-6 or np.std(visual) < 1e-6:
                    continue
                corr = float(np.corrcoef(visual, motion)[0, 1])
                candidates.append((abs(corr), corr, float(lag), video_axis, gyro_axis))
    candidates.sort(reverse=True)
    best = candidates[0]
    roll_windows = []
    for start in np.arange(0, max(float(times[-1]) - 2.5, 0.01), 2.0):
        selected = (times >= start) & (times < start + 2.5)
        if np.count_nonzero(selected) < 60:
            continue
        visual = rates[selected, 2]
        if np.std(visual) < 0.02:
            continue
        curve = []
        for lag in lag_grid:
            motion = np.interp(times[selected] + lag, gyro[:, 0], gyro[:, 3])
            curve.append(float(np.corrcoef(visual, motion)[0, 1]))
        best_index = int(np.argmax(np.abs(curve)))
        peak = abs(curve[best_index])
        near = lag_grid[np.abs(curve) >= peak - 0.001]
        roll_windows.append({"seconds": [round(float(start), 2), round(float(start + 2.5), 2)],
                             "pairs": int(np.count_nonzero(selected)),
                             "bestLagMs": round(float(lag_grid[best_index] * 1000), 1),
                             "correlation": round(curve[best_index], 4),
                             "nearPeakLagRangeMs": [round(float(near.min() * 1000), 1),
                                                    round(float(near.max() * 1000), 1)]})
    return {"movie": str(path), "videoFrames": len(pts), "decodedFrames": decoded,
            "usableOpticalPairs": len(times), "gyroSamples": len(gyro),
            "gyroIntervalMs": {"median": float(np.median(np.diff(gyro[:, 0])) * 1000),
                               "max": float(np.max(np.diff(gyro[:, 0])) * 1000)},
            "strongest": [{"correlation": round(c[1], 4), "gyroLaterMs": round(c[2] * 1000, 1),
                           "videoAxis": "xyr"[c[3]], "gyroAxis": "xyz"[c[4] - 1]}
                          for c in candidates if abs(c[2] - best[2]) < 0.0005][:2],
            "topByAxis": [{"correlation": round(c[1], 4), "gyroLaterMs": round(c[2] * 1000, 1),
                           "videoAxis": "xyr"[c[3]], "gyroAxis": "xyz"[c[4] - 1]}
                          for c in [max((v for v in candidates if v[3] == axis), key=lambda x: x[0])
                                    for axis in (0, 1, 2)]],
            "rollWindows": roll_windows,
            "warning": "Feature translation is a proxy; scene depth, rolling shutter and EIS can bias lag."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("movie", type=Path)
    args = parser.parse_args()
    print(json.dumps(estimate(args.movie), indent=2))
