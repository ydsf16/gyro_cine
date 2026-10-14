#!/usr/bin/env python3
"""Repair GyroCine metadata order into a new MOV, without reencoding."""
import argparse
import shutil
import struct


def atoms(data):
    offset = 0
    while offset < len(data):
        size, kind = struct.unpack_from('>I4s', data, offset)
        header = 8
        if size == 1:
            size = struct.unpack_from('>Q', data, offset + 8)[0]
            header = 16
        if size == 0:
            size = len(data) - offset
        if size < header or offset + size > len(data):
            raise ValueError('Invalid atom')
        yield kind, data[offset:offset + size], header
        offset += size


def rank(track, header):
    media = next((b[h:] for k, b, h in atoms(track[header:]) if k == b'mdia'), b'')
    handler = next((b[h:] for k, b, h in atoms(media) if k == b'hdlr'), b'')
    if handler[8:12] in (b'vide', b'soun'):
        return 0
    if b'Sony RTMD' in handler or b'Gyroflow' in handler:
        return 1
    return 2


def repair(source, destination):
    # Exclusive creation protects both the source and any existing destination.
    with open(source, 'rb') as src, open(destination, 'xb') as dst:
        shutil.copyfileobj(src, dst)
    with open(destination, 'r+b') as f:
        f.seek(0, 2)
        length = f.tell()
        offset = 0
        while offset < length:
            f.seek(offset)
            size, kind = struct.unpack('>I4s', f.read(8))
            header = 8
            if size == 1:
                size = struct.unpack('>Q', f.read(8))[0]
                header = 16
            if size == 0:
                size = length - offset
            if size < header or offset + size > length:
                raise ValueError('Invalid MOV')
            if kind == b'moov':
                payload = f.read(size - header)
                children = list(atoms(payload))
                tracks = iter(sorted((c for c in children if c[0] == b'trak'), key=lambda c: rank(c[1], c[2])))
                updated = b''.join(next(tracks)[1] if k == b'trak' else b for k, b, h in children)
                assert len(updated) == len(payload)
                f.seek(offset + header)
                f.write(updated)
            offset += size


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('source')
    p.add_argument('destination')
    a = p.parse_args()
    repair(a.source, a.destination)
