#!/usr/bin/env python3
"""Verify device MOV intrinsics against retained camera_frames.jsonl and capture logs.
Run with Debug enabled in the app; pass one or more pulled MOV paths.
"""
import json
import pathlib
import statistics
import struct
import subprocess
import sys


def atoms(data):
    pos = 0
    while pos + 8 <= len(data):
        size, kind = struct.unpack_from('>I4s', data, pos)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, pos + 8)[0]
            header = 16
        if size == 0:
            size = len(data) - pos
        assert size >= header and pos + size <= len(data)
        yield kind, data[pos + header:pos + size]
        pos += size


def validate(path):
    # Read only the final moov, not the video payload.
    moov = None
    with path.open('rb') as stream:
        while header := stream.read(8):
            size, kind = struct.unpack('>I4s', header)
            header_size = 8
            if size == 1:
                size = struct.unpack('>Q', stream.read(8))[0]
                header_size = 16
            assert size >= header_size
            if kind == b'moov':
                moov = stream.read(size - header_size)
            else:
                stream.seek(size - header_size, 1)
    notes = [json.loads(payload) for kind, body in atoms(moov) if kind == b'udta'
             for tag, payload in atoms(body) if tag == b'rmin']
    note = notes[-1]
    assert note['intrinsic_source'] == 'CameraIntrinsicMatrix'
    source = [json.loads(line) for line in path.with_suffix('.camera_frames.jsonl').read_text().splitlines()]
    first_host = None
    for log in path.parent.glob('focus-*.jsonl'):
        for line in log.read_text().splitlines():
            event = json.loads(line)
            if event['eventType'] == 'record_delegate_start' and pathlib.Path(event['data']['path']).name == path.name:
                first_host = event['data']['firstHost']
    assert first_host is not None
    probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_packets', '-of', 'json', str(path)]))
    video = next(s for s in probe['streams'] if s['codec_type'] == 'video')
    pts = sorted(float(p['pts_time']) for p in probe['packets'] if p['stream_index'] == video['index'])
    matched = [min(source, key=lambda f: abs(f['hostTime'] - (first_host + t - pts[0]))) for t in pts]
    errors = [abs(f['hostTime'] - (first_host + t - pts[0])) for f, t in zip(matched, pts)]
    interval = statistics.median(b-a for a, b in zip(pts, pts[1:]))
    assert max(errors) < min(.01, interval * .45)
    assert len({f['hostTime'] for f in matched}) == len(pts)
    assert all((f['width'], f['height']) == (video['width'], video['height']) for f in matched)
    mean = [statistics.mean(f['matrix'][i] for f in matched) for i in range(9)]
    assert note['intrinsic_frame_count'] == len(pts)
    assert max(abs(a-b) for a, b in zip(mean, note['intrinsic_mean'])) < 1e-7
    embedded = sum(note['lens_profile']['fisheye_params']['camera_matrix'], [])
    assert max(abs(a-b) for a, b in zip(mean, embedded)) < 1e-7
    telemetry = next(s for s in probe['streams'] if s.get('codec_tag_string') in ('gyrf', 'rtmd'))
    packets = [p for p in probe['packets'] if p['stream_index'] == telemetry['index']]
    if telemetry['codec_tag_string'] == 'gyrf':
        import gyroflow_pb2
        with path.open('rb') as stream:
            for p, frame in zip(packets, matched, strict=True):
                stream.seek(int(p['pos']))
                message = gyroflow_pb2.Main()
                message.ParseFromString(stream.read(int(p['size'])))
                values = list(message.frame.lens[0].camera_intrinsic_matrix)
                assert max(abs(a-b) for a, b in zip(values, frame['matrix'], strict=True)) < .001
    return {'file': path.name, 'frames': len(pts), 'mean_K': mean, 'max_alignment_ms': max(errors)*1000,
            'telemetry': telemetry['codec_tag_string'], 'result': 'PASS'}


if __name__ == '__main__':
    for arg in sys.argv[1:]:
        print(json.dumps(validate(pathlib.Path(arg)), ensure_ascii=False))
