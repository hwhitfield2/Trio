import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import backtest, baseline, gates, schema


def synthetic_frames(count: int = 400) -> list[dict]:
    """Slow sinusoid-ish glucose so linear-trend beats last-value."""
    frames = []
    value = 120.0
    delta = 1.5
    values = []
    for i in range(count):
        value += delta
        if value > 200 or value < 80:
            delta = -delta
            value += 2 * delta
        values.append(value)
    for i in range(count):
        labels = {}
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            j = i + horizon // schema.FRAME_INTERVAL_MINUTES
            if j < count:
                labels[str(horizon)] = values[j]
        frames.append({
            "t": float(i * schema.FRAME_INTERVAL_MINUTES),
            "glucose": values[i],
            "carbs": 0.0,
            "bolus": 0.0,
            "temp_basal_rate": None,
            "iob": 0.0,
            "labels": labels,
        })
    return frames


class BacktestTests(unittest.TestCase):
    def test_metrics_shape(self):
        metrics = backtest.run_backtest(synthetic_frames(), baseline.last_value)
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            entry = metrics[str(horizon)]
            self.assertIsNotNone(entry["rmse"])
            self.assertGreater(entry["n"], 0)

    def test_trend_beats_last_value_on_trending_data(self):
        frames = synthetic_frames()
        trend = backtest.run_backtest(frames, baseline.linear_trend)
        last = backtest.run_backtest(frames, baseline.last_value)
        self.assertLess(trend["30"]["rmse"], last["30"]["rmse"])


class GateTests(unittest.TestCase):
    def test_candidate_beating_champion_passes(self):
        frames = synthetic_frames()
        champion = backtest.run_backtest(frames, baseline.last_value)
        candidate = backtest.run_backtest(frames, baseline.linear_trend)
        comparison = gates.compare_backtests(candidate, champion)
        replay = gates.hypo_safety_replay([])
        verdict = gates.promotion_verdict(comparison, replay)
        self.assertTrue(verdict["promote"])

    def test_worse_candidate_fails(self):
        frames = synthetic_frames()
        champion = backtest.run_backtest(frames, baseline.linear_trend)
        candidate = backtest.run_backtest(frames, baseline.last_value)
        comparison = gates.compare_backtests(candidate, champion)
        verdict = gates.promotion_verdict(comparison, gates.hypo_safety_replay([]))
        self.assertFalse(verdict["promote"])

    def test_hypo_replay_blocks_dosing_in_low(self):
        replay = gates.hypo_safety_replay([
            {"glucose": 70, "smb": 0.3, "rate": 0.0, "profile_rate": 1.0},
        ])
        self.assertFalse(replay["passed"])
        self.assertEqual(len(replay["violations"]), 1)

    def test_hypo_replay_allows_reduction_in_low(self):
        replay = gates.hypo_safety_replay([
            {"glucose": 70, "smb": 0.0, "rate": 0.0, "profile_rate": 1.0},
            {"glucose": 150, "smb": 0.5, "rate": 2.0, "profile_rate": 1.0},
        ])
        self.assertTrue(replay["passed"])

    def test_too_few_samples_fails_gate(self):
        frames = synthetic_frames(count=30)  # far below MIN_SAMPLES_PER_HORIZON
        champion = backtest.run_backtest(frames, baseline.last_value)
        candidate = backtest.run_backtest(frames, baseline.linear_trend)
        comparison = gates.compare_backtests(candidate, champion)
        self.assertFalse(all(r["passed"] for r in comparison.values()))


if __name__ == "__main__":
    unittest.main()
