import json
import subprocess
import tempfile
import unittest
from pathlib import Path

from validate_recording import validate


class ValidatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.folder = Path(self.temp.name)
        subprocess.run([
            "ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "color=s=64x64:r=30",
            "-frames:v", "3", "-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
            str(self.folder / "clip.mov")
        ], check=True, capture_output=True)
        rows = [
            {"magicString": "GyroflowProtobuf", "protocolVersion": 1,
             "header": {"camera": {"cameraBrand": "Apple", "cameraModel": "iPhone"},
                        "clip": {"frameWidth": 64, "frameHeight": 64,
                                 "durationUs": 100000, "fileFrameRate": 30}},
             "frame": {"frameNumber": 1, "imu": [
                 {"sampleTimestampUs": 0, "gyroscopeX": 180, "accelerometerX": 9.80665},
                 {"sampleTimestampUs": 10000, "gyroscopeX": 180, "accelerometerX": 9.80665}]}},
            {"frame": {"frameNumber": 2, "imu": []}},
            {"frame": {"frameNumber": 3, "imu": []}},
        ]
        (self.folder / "clip.jsonl").write_text("\n".join(map(json.dumps, rows)) + "\n")
        (self.folder / "imu_raw.jsonl").write_text(
            json.dumps({"kind": "gyro", "timestamp": 1, "x": 3.14159, "y": 0, "z": 0}) + "\n" +
            json.dumps({"kind": "accel", "timestamp": 1.01, "x": 9.80665, "y": 0, "z": 0}) + "\n")
        (self.folder / "diagnostics.json").write_text(json.dumps({
            "actualFrameCount": 3, "status": "completed_unverified_on_device"}))

    def tearDown(self):
        self.temp.cleanup()

    def test_valid_proto_and_mov(self):
        result = validate(self.folder)
        self.assertTrue(result["pass"], result["errors"])
        self.assertEqual(result["frameCount"], 3)

    def test_quoted_numeric_rejected(self):
        path = self.folder / "clip.jsonl"
        path.write_text(path.read_text().replace('"sampleTimestampUs": 0', '"sampleTimestampUs": "0"'))
        self.assertFalse(validate(self.folder)["pass"])

    def test_bad_frame_sequence_rejected(self):
        path = self.folder / "clip.jsonl"
        path.write_text(path.read_text().replace('"frameNumber": 2', '"frameNumber": 4'))
        self.assertFalse(validate(self.folder)["pass"])


if __name__ == "__main__":
    unittest.main()
