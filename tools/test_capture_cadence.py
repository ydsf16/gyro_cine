import unittest
from analyze_capture_cadence import summarize


class CadenceTests(unittest.TestCase):
    def test_regular(self):
        report = summarize([i/60 for i in range(600)], 60)
        self.assertEqual(report['long_gaps'], 0)
        self.assertAlmostEqual(report['average_fps_over_span'], 60)

    def test_missing_frames(self):
        report = summarize([0, 1/60, 3/60, 6/60], 60)
        self.assertEqual(report['long_gaps'], 2)
        self.assertEqual(report['estimated_missing_frames'], 3)
        self.assertAlmostEqual(report['max_gap_ms'], 50)

    def test_broadcast_and_jitter(self):
        report = summarize([i/59.94 + (0.0001 if i % 2 else 0) for i in range(600)], 59.94)
        self.assertEqual(report['long_gaps'], 0)

    def test_invalid(self):
        for times, fps in [([0,0],60), ([0],60), ([0,float('nan')],60), ([0,1],0)]:
            with self.assertRaises(ValueError): summarize(times, fps)
