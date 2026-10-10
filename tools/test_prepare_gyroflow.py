import json
from pathlib import Path
import tempfile
import unittest
from prepare_gyroflow import prepare

class PreparationTests(unittest.TestCase):
    def test_preserves_sample_times_and_radians_without_duplicate_union_samples(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            (folder / 'diagnostics.json').write_text(json.dumps({'clock': {'firstVideoPTSSeconds': 100}, 'firstVideoPTSSeconds': 0.01}))
            rows = [{'kind': 'gyro', 'timestamp': 100.02, 'x': 3.14159, 'y': -2, 'z': 0},
                    {'kind': 'accel', 'timestamp': 100.025, 'x': 1, 'y': 2, 'z': 3},
                    {'kind': 'gyro', 'timestamp': 100.03, 'x': 1, 'y': 0, 'z': 2}]
            (folder / 'imu_raw.jsonl').write_text('\n'.join(map(json.dumps, rows)))
            report = prepare(folder, folder / 'offline', 'XYZ')
            data = (folder / 'offline/clip.gcsv').read_text().split('t,gx,gy,gz\n')[1].splitlines()
            self.assertEqual(report['gyroCount'], 2)
            self.assertEqual(len(data), 2)
            sample = list(map(float, data[0].split(',')))
            self.assertAlmostEqual(sample[0], .03)
            self.assertEqual(sample[1:], [3.14159, -2, 0])
            self.assertFalse(report['hardwareReadoutKnown'])
            with self.assertRaises(ValueError): prepare(folder, folder / 'offline', 'XYZ')

    def test_rejects_invalid_orientation(self):
        with self.assertRaises(ValueError): prepare(Path('/unused'), Path('/unused/out'), 'XXY')
