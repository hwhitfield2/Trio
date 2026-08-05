import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import estimator

LAG = estimator.DEFAULT_LAG_MINUTES


def delayed_readings(true_fn, times, lag=LAG, noise_fn=None):
    """CGM readings: the true value `lag` minutes before delivery time."""
    readings = []
    for i, t in enumerate(times):
        value = true_fn(t - lag)
        if noise_fn is not None:
            value += noise_fn(i)
        readings.append((t, value))
    return readings


class StateEstimatorTests(unittest.TestCase):
    def test_flat_glucose_converges_to_reading(self):
        times = [5.0 * i for i in range(48)]
        readings = delayed_readings(lambda t: 120.0, times)
        estimates = estimator.replay(readings)
        final = estimates[-1]
        self.assertAlmostEqual(final.glucose_now, 120.0, delta=1.0)
        self.assertAlmostEqual(final.trend_per_minute, 0.0, delta=0.05)

    def test_rising_glucose_lag_recovered(self):
        # True glucose rises 2 mg/dL/min; a raw reading is 20 mg/dL behind "now".
        slope = 2.0
        times = [5.0 * i for i in range(48)]
        true_fn = lambda t: 100.0 + slope * t  # noqa: E731
        readings = delayed_readings(true_fn, times)
        estimates = estimator.replay(readings)

        final_time = times[-1]
        true_now = true_fn(final_time)
        raw_reading = readings[-1][1]
        estimate = estimates[-1].glucose_now

        raw_error = abs(raw_reading - true_now)          # = slope * lag = 20
        est_error = abs(estimate - true_now)
        self.assertGreater(raw_error, 15.0)
        # The estimator must recover most of the lag.
        self.assertLess(est_error, raw_error / 3)
        self.assertAlmostEqual(estimates[-1].trend_per_minute, slope, delta=0.5)

    def test_estimator_beats_raw_readings_rmse(self):
        # Sinusoidal glucose (period 4 h, amplitude 40) with deterministic noise.
        times = [5.0 * i for i in range(96)]
        true_fn = lambda t: 140.0 + 40.0 * math.sin(2 * math.pi * t / 240.0)  # noqa: E731
        noise_fn = lambda i: 4.0 * math.sin(1.7 * i)  # bounded pseudo-noise  # noqa: E731
        readings = delayed_readings(true_fn, times, noise_fn=noise_fn)
        estimates = estimator.replay(readings)

        true_series = [(t, true_fn(t)) for t in times]
        est_rmse = estimator.lag_compensation_error(true_series, estimates)

        raw_errors = [reading - true_fn(t) for t, reading in readings]
        tail = raw_errors[len(raw_errors) // 2:]
        raw_rmse = math.sqrt(sum(e * e for e in tail) / len(tail))

        self.assertLess(est_rmse, raw_rmse)

    def test_duplicate_delivery_ignored(self):
        est = estimator.StateEstimator()
        est.update(0.0, 120.0)
        first = est.update(5.0, 122.0)
        duplicate = est.update(5.0, 122.0)  # same timestamp re-delivered
        self.assertEqual(first.glucose_now, duplicate.glucose_now)

    def test_implausible_jump_flagged_and_not_tracked(self):
        est = estimator.StateEstimator()
        est.update(0.0, 120.0)
        est.update(5.0, 121.0)
        result = est.update(10.0, 40.0)  # compression-low style drop
        self.assertTrue(result.reading_suspect)
        # The estimate must not chase the suspect reading.
        self.assertGreater(result.glucose_now, 100.0)

    def test_gap_beyond_bridge_marked_stale(self):
        est = estimator.StateEstimator()
        est.update(0.0, 120.0)
        result = est.update(20.0, 125.0)  # 20-min outage
        self.assertTrue(result.stale)

    def test_variance_grows_across_gap(self):
        est = estimator.StateEstimator()
        est.update(0.0, 120.0)
        after_first = est.update(5.0, 120.0)
        est2 = estimator.StateEstimator()
        est2.update(0.0, 120.0)
        after_gap = est2.update(15.0, 120.0)
        self.assertGreater(after_gap.variance, after_first.variance)

    def test_project_dead_reckons_trend(self):
        est = estimator.StateEstimator()
        times = [5.0 * i for i in range(48)]
        for t, value in delayed_readings(lambda t: 100.0 + 2.0 * t, times):
            est.update(t, value)
        now = est.project(0.0)
        ahead = est.project(15.0)
        self.assertGreater(ahead, now + 15.0)  # ~2 mg/dL/min trend


if __name__ == "__main__":
    unittest.main()
