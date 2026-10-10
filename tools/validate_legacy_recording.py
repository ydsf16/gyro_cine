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
    assert len(samples) == len(gyro) > 0
    first = diagnostics['clock']['firstVideoPTSSeconds']
    host_first = diagnostics['clock'].get('firstVideoHostPTSSeconds', first)
    asset_first = diagnostics['firstVideoPTSSeconds']
    for row, event in zip(samples, gyro):
        mapping = diagnostics.get('recordedClockMap')
        time = ((event['timestamp'] - mapping['origin']) * mapping['slope'] + mapping['intercept']) if mapping else event['timestamp'] - host_first + asset_first
        expected = [time, event['x'], event['y'], event['z']]
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
                frameCount=len(pts), gyroCount=len(gyro), accelCount=sum(e['kind']=='accel' for e in raw),
                sourceToAssetResidualMs=residual*1000, durationSeconds=diagnostics['actualDurationSeconds'],
                gyroPeakRadPerSec=max(math.sqrt(e['x']**2+e['y']**2+e['z']**2) for e in gyro),
                cameraMatrix=profile['fisheye_params']['camera_matrix'],
                stabilizationQualityVerified=False, distortionCalibrated=False)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('folder', type=Path)
    args = parser.parse_args()
    print(json.dumps(validate(args.folder), indent=2, ensure_ascii=False))
