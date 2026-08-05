import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import insulin


class InsulinCurveTests(unittest.TestCase):
    def test_iob_boundaries(self):
        self.assertEqual(insulin.iob_fraction(0), 1.0)
        self.assertEqual(insulin.iob_fraction(-5), 1.0)
        self.assertEqual(insulin.iob_fraction(insulin.DEFAULT_DIA_MINUTES), 0.0)
        self.assertEqual(insulin.iob_fraction(insulin.DEFAULT_DIA_MINUTES + 60), 0.0)

    def test_iob_monotonically_decreasing(self):
        values = [insulin.iob_fraction(t) for t in range(0, 300, 5)]
        for earlier, later in zip(values, values[1:]):
            self.assertGreaterEqual(earlier, later)

    def test_iob_halfway_plausible(self):
        # With DIA 5h / peak 75min, roughly half the insulin should be used
        # somewhere well before the midpoint of DIA.
        self.assertLess(insulin.iob_fraction(150), 0.5)
        self.assertGreater(insulin.iob_fraction(60), 0.5)

    def test_activity_peaks_near_peak_time(self):
        times = list(range(5, 295, 5))
        activities = [insulin.activity_fraction(t) for t in times]
        peak_t = times[activities.index(max(activities))]
        self.assertAlmostEqual(peak_t, insulin.DEFAULT_PEAK_MINUTES, delta=10)

    def test_activity_integrates_to_one(self):
        total = sum(insulin.activity_fraction(t) for t in range(0, 300)) * 1.0
        self.assertAlmostEqual(total, 1.0, delta=0.02)

    def test_iob_from_boluses_sums(self):
        boluses = [(0.0, 1.0), (0.0, 2.0)]
        self.assertAlmostEqual(insulin.iob_from_boluses(0.0, boluses), 3.0)
        self.assertLess(insulin.iob_from_boluses(120.0, boluses), 3.0)
        # Future boluses don't count.
        self.assertEqual(insulin.iob_from_boluses(-10.0, boluses), 0.0)

    def test_invalid_peak_raises(self):
        with self.assertRaises(ValueError):
            insulin.iob_fraction(10, dia_minutes=100, peak_minutes=100)


if __name__ == "__main__":
    unittest.main()
