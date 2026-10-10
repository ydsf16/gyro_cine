#!/usr/bin/env python3
"""Compare image motion. Requires OpenCV/numpy; does not prove lens or hardware calibration."""
import argparse
import json
import math
import subprocess
from pathlib import Path
import cv2
import numpy as np


def measure(path):
    w, h = 640, 360
    command = ['ffmpeg', '-v', 'error', '-i', str(path), '-an', '-vf', f'scale={w}:{h}', '-pix_fmt', 'gray', '-f', 'rawvideo', 'pipe:1']
    angles, displacement, inliers = [], [], []
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    previous = None
    while True:
        data = process.stdout.read(w*h)
        if len(data) != w*h: break
        current = np.frombuffer(data, np.uint8).reshape(h, w)
        angle, delta = np.nan, [np.nan, np.nan]
        if previous is not None:
            points = cv2.goodFeaturesToTrack(previous, maxCorners=400, qualityLevel=.01, minDistance=8)
            if points is not None and len(points) >= 20:
                tracked, status, _ = cv2.calcOpticalFlowPyrLK(previous, current, points, None)
                keep = status.ravel().astype(bool)
                if keep.sum() >= 20:
                    matrix, mask = cv2.estimateAffinePartial2D(points[keep], tracked[keep], method=cv2.RANSAC, ransacReprojThreshold=2)
                    if matrix is not None and mask.sum() >= 20 and mask.mean() >= .6:
                        angle = math.degrees(math.atan2(matrix[1, 0], matrix[0, 0]))
                        delta = (matrix @ np.array([w/2, h/2, 1]) - [w/2, h/2]).tolist()
                        inliers.append(float(mask.mean()))
            angles.append(angle); displacement.append(delta)
        previous = current.copy()
    process.stdout.close()
    if process.wait() != 0: raise RuntimeError('ffmpeg decoding failed')
    a = np.array(angles); d = np.array(displacement)
    valid = np.isfinite(a)
    adjacent = valid[1:] & valid[:-1]
    angle_changes = np.diff(a)[adjacent]
    d_changes = np.diff(d, axis=0)[adjacent]
    if adjacent.sum() < 100: raise RuntimeError('insufficient reliable motion tracks')
    return a, d, {'decodedFrames': len(angles)+1, 'validFramePairs': int(valid.sum()),
            'adjacentPairsForJitter': int(adjacent.sum()),
            'medianInlierFraction': float(np.median(inliers)),
            'angleStepChangeRMSDegrees': float(np.sqrt(np.mean(angle_changes**2))),
            'centerStepChangeRMSPixelsAt640': float(np.sqrt(np.mean(np.sum(d_changes**2, axis=1))))}


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('original',type=Path); p.add_argument('stabilized',type=Path); p.add_argument('--report',type=Path,required=True)
    a=p.parse_args(); oa, od, original=measure(a.original); sa, sd, stabilized=measure(a.stabilized)
    if len(oa) != len(sa): raise RuntimeError('frame counts differ')
    valid = np.isfinite(oa) & np.isfinite(sa)
    adjacent = valid[1:] & valid[:-1]
    if adjacent.sum() < 100: raise RuntimeError('insufficient common motion tracks')
    for angles, delta, report in ((oa, od, original), (sa, sd, stabilized)):
        report['commonAdjacentPairs'] = int(adjacent.sum())
        report['angleStepChangeRMSDegrees'] = float(np.sqrt(np.mean(np.diff(angles)[adjacent]**2)))
        report['centerStepChangeRMSPixelsAt640'] = float(np.sqrt(np.mean(np.sum(np.diff(delta,axis=0)[adjacent]**2,axis=1))))
    result={'method':'Adjacent affine image-motion step changes on identical common frame pairs after 640x360 rescaling; RANSAC inlier >=60%, >=20 tracks',
            'limitations':'Intentional motion, parallax, OIS and changing crop can affect this metric. Not a calibrated axis/readout or visual-quality acceptance.',
            'original':original,'stabilized':stabilized}
    for key in ('angleStepChangeRMSDegrees','centerStepChangeRMSPixelsAt640'):
        result[key+'Ratio']=stabilized[key]/original[key]
    a.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))

if __name__=='__main__': main()
