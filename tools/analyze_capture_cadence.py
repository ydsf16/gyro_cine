#!/usr/bin/env python3
"""Inspect encoded frame cadence, and optionally correlate gaps with retained K samples."""
import argparse
import bisect
import json
import math
from pathlib import Path
import statistics
import subprocess


def summarize(timestamps, fps):
    if not math.isfinite(fps) or fps <= 0:
        raise ValueError('FPS must be finite and positive')
    if len(timestamps) < 2 or not all(math.isfinite(t) for t in timestamps):
        raise ValueError('Need at least two finite frame timestamps')
    ordered = sorted(timestamps)
    gaps = [(a, b) for a, b in zip(ordered, ordered[1:])]
    if any(b <= a for a, b in gaps):
        raise ValueError('Duplicate or non-increasing frame timestamps')
    large = [(a, b) for a, b in gaps if b-a > 1.5/fps]
    duration = ordered[-1]-ordered[0]+1/fps
    return {
        'frames': len(ordered), 'nominal_fps': fps,
        'estimated_span_seconds': duration, 'average_fps_over_span': len(ordered)/duration,
        'median_gap_ms': statistics.median(b-a for a,b in gaps)*1000,
        'max_gap_ms': max(b-a for a,b in gaps)*1000,
        'long_gaps': len(large),
        'estimated_missing_frames': sum(max(0, round((b-a)*fps)-1) for a,b in large),
        'gap_intervals': [{'from': a, 'to': b} for a,b in large],
    }


def inspect(movie, fps):
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_streams',
        '-show_packets', '-of', 'json', str(movie)]))
    stream = probe['streams'][0]
    packets = [p for p in probe['packets'] if 'D' not in p.get('flags', '')]
    times = sorted(float(p['pts_time']) for p in packets)
    result = summarize(times, fps)
    result.update(file=movie.name, width=stream['width'], height=stream['height'],
                  discarded_packets=len(probe['packets'])-len(packets))
    first_host = None
    health = []
    for log in movie.parent.glob('focus-*.jsonl'):
        rows = []
        for line in log.read_text().splitlines():
            try: rows.append(json.loads(line))
            except json.JSONDecodeError: continue  # A copied live log can end in a partial line.
        starts = [r for r in rows if r.get('eventType') == 'record_delegate_start'
                  and Path(r['data']['path']).name == movie.name]
        if starts:
            first_host = starts[-1]['data']['firstHost']
            health = [r['data'] for r in rows if r.get('eventType') == 'recording_health'
                      and first_host <= r['monotonicSeconds'] <= first_host + result['estimated_span_seconds']]
            break
    result['health_samples'] = len(health)
    result['thermal_states'] = sorted({r['thermalState'] for r in health})
    result['pressure_levels'] = sorted({r['pressureLevel'] for r in health})
    evidence = movie.with_suffix('.camera_frames.jsonl')
    if first_host is not None and evidence.exists():
        frames = [json.loads(l) for l in evidence.read_text().splitlines()]
        host_times = sorted(f['hostTime'] for f in frames)
        # Ignore samples within 6 ms of a MOV gap edge, tolerating observed clock matching jitter.
        interior = []
        for gap in result['gap_intervals']:
            a = first_host + gap['from']-times[0]+.006
            b = first_host + gap['to']-times[0]-.006
            interior.append(max(0, bisect.bisect_left(host_times, b)-bisect.bisect_right(host_times, a)))
        result['long_gaps_with_intermediate_K'] = sum(n>0 for n in interior)
        result['raw_K_frames'] = len(frames)
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('movies', nargs='+', type=Path)
    parser.add_argument('--fps', required=True, type=float, help='Requested nominal frame rate')
    args = parser.parse_args()
    for movie in args.movies:
        print(json.dumps(inspect(movie, args.fps), ensure_ascii=False))
