#!/usr/bin/env python3
"""Validate a captured fixed-lens bundle against raw evidence and encoded MOV."""
import argparse
import csv
import json
import math
import subprocess
from pathlib import Path


def validate(folder):
    load = lambda name: json.loads((folder / name).read_text())
    rows = lambda name: [json.loads(s) for s in (folder / name).read_text().splitlines() if s]
    diagnostics = load('diagnostics.json')
    profile = load('lens_profile.json')
    project = load('clip.gyroflow')
    raw = rows('imu_raw.jsonl')
    gyro = [e for e in raw if e['kind'] == 'gyro']
    evidence = rows('video_samples.jsonl')
    lines = (folder / 'clip.gcsv').read_text().splitlines()
    assert lines[:2] == ['GYROFLOW IMU LOG', 'version,1.3']
    assert 'tscale,1' in lines and 'gscale,1' in lines
    start = lines.index('t,gx,gy,gz')
    samples = [[float(x) for x in row] for row in csv.reader(lines[start+1:])]
    assert len(gyro) > 0
    first = diagnostics['clock']['firstVideoPTSSeconds']
    host_first = diagnostics['clock'].get('firstVideoHostPTSSeconds', first)
    asset_first = diagnostics['firstVideoPTSSeconds']
    mapping = diagnostics.get('recordedClockMap')
    def video_time(event):
        return ((event['timestamp'] - mapping['origin']) * mapping['slope'] + mapping['intercept']) if mapping else event['timestamp'] - host_first + asset_first
    mapped = [[video_time(e), e['x'], e['y'], e['z']] for e in gyro]
    alignment = diagnostics.get('gcsvAlignment')
    if alignment:
        start_time = asset_first
        end_time = start_time + alignment['videoEndSeconds']
        assert mapped[0][0] <= start_time < end_time <= mapped[-1][0]
        def boundary(time):
            upper = next(i for i, sample in enumerate(mapped) if sample[0] >= time)
            if mapped[upper][0] == time:
                return mapped[upper], 0
            assert upper > 0
            before, after = mapped[upper-1], mapped[upper]
            gap = after[0] - before[0]
            assert 0 < gap <= .030
            fraction = (time - before[0]) / gap
            return [time] + [a + (b-a)*fraction for a,b in zip(before[1:],after[1:])], gap
        first_sample, first_gap = boundary(start_time)
        last_sample, last_gap = boundary(end_time)
        expected_rows = [first_sample] + [e for e in mapped if start_time < e[0] < end_time] + [last_sample]
        expected_rows = [[e[0]-start_time] + e[1:] for e in expected_rows]
        assert len(samples) == alignment['sampleCount'] == len(expected_rows)
        assert abs(alignment['preRollMs'] - (start_time-mapped[0][0])*1000) < 1e-6
        assert abs(alignment['postRollMs'] - (mapped[-1][0]-end_time)*1000) < 1e-6
        assert abs(alignment['maximumBoundaryInterpolationGapMs'] - max(first_gap,last_gap)*1000) < 1e-6
        assert abs(project['offsets']['0']) < 1e-10
    else:
        expected_rows = mapped
        assert len(samples) == len(expected_rows)
    for row, expected in zip(samples, expected_rows):
        assert len(row) == 4 and all(math.isfinite(x) for x in row)
        assert all(abs(a-b) < 1e-10 for a,b in zip(row, expected))
    assert all(a[0] < b[0] for a,b in zip(samples, samples[1:]))
    probe = json.loads(subprocess.check_output(['ffprobe','-v','error','-select_streams','v:0',
        '-show_frames','-show_streams','-show_entries','frame=pts_time:stream=codec_name,width,height',
        '-of','json',str(folder/'clip.mov')]))
    pts = [float(f['pts_time']) for f in probe['frames']]
    assert len(pts) == len(evidence) == diagnostics['actualFrameCount']
    assert probe['streams'][0]['codec_name'] == 'hevc'
    residual = max(abs(e['sourcePTSSeconds'] - first + asset_first - t) for e,t in zip(evidence,pts))
    assert residual <= .001
    assert all(len(e.get('cameraIntrinsicMatrix', [])) == 9 for e in evidence)
    assert all(e['activeVideoStabilizationMode'] == 0 for e in evidence)
    assert project['calibration_data'] == profile
    assert abs(project['offsets']['0'] - samples[0][0]*1000) < 1e-8
    assert diagnostics['selectedLens']['name'] in profile['camera_setting']
    assert diagnostics['status'] == 'completed_unverified_on_device'
    return dict(status='PASS-format-and-clock-mapping', lens=diagnostics['selectedLens'],
                frameCount=len(pts), rawGyroCount=len(gyro), gcsvGyroCount=len(samples),
                accelCount=sum(e['kind']=='accel' for e in raw),
                sourceToAssetResidualMs=residual*1000, durationSeconds=diagnostics['actualDurationSeconds'],
                gyroPeakRadPerSec=max(math.sqrt(e['x']**2+e['y']**2+e['z']**2) for e in gyro),
                cameraMatrix=profile['fisheye_params']['camera_matrix'],
                stabilizationQualityVerified=False, distortionCalibrated=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.folder), indent=2, ensure_ascii=False))
