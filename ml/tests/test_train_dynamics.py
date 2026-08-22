import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import train_dynamics
from trioml import features, oref

from test_oref import START_MINUTES, determination


class StubForecaster:
    """predict() shaped like model.QuantileForecaster without needing torch."""

    def __init__(self, offset: float = 5.0):
        self.offset = offset

    def predict(self, sample: dict) -> dict[str, list[float]]:
        now = sample["now_glucose"]
        return {
            "p10": [now - 30.0] * features.HORIZON_STEPS,
            "p50": [now + self.offset] * features.HORIZON_STEPS,
            "p90": [now + 60.0] * features.HORIZON_STEPS,
        }


def make_sample(t_minutes: float, now_glucose: float, labels: dict) -> dict:
    history_step = [features.normalize_glucose(now_glucose), 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0]
    return {
        "t": t_minutes,
        "now_glucose": now_glucose,
        "history": [list(history_step) for _ in range(features.HISTORY_STEPS)],
        "plan": [[0.0, 0.0] for _ in range(features.HORIZON_STEPS)],
        "target": [0.0] * features.HORIZON_STEPS,
        "target_mask": [1.0] * features.HORIZON_STEPS,
        "labels": labels,
    }


class EvaluateHeldoutTests(unittest.TestCase):
    def test_oref_subset_only_scores_pairs_oref_predicted(self):
        # Two samples; oref only has a determination near the first one.
        samples = [
            make_sample(START_MINUTES, 120.0, {"30": 130.0, "60": 140.0}),
            make_sample(START_MINUTES + 120, 150.0, {"30": 155.0}),
        ]
        forecasts = oref.OrefForecasts([
            determination(0, {"iob": [120 + 2 * i for i in range(30)]}),
        ])
        evaluation = train_dynamics.evaluate_heldout(StubForecaster(), samples, forecasts)

        self.assertEqual(evaluation["candidate"]["30"]["n"], 2)
        self.assertEqual(evaluation["oref"]["30"]["n"], 1)
        self.assertEqual(evaluation["candidate_oref_subset"]["30"]["n"], 1)
        self.assertEqual(evaluation["oref"]["60"]["n"], 1)
        # oref's iob curve: step 6 → 132, actual 130 → error 2.
        self.assertAlmostEqual(evaluation["oref"]["30"]["rmse"], 2.0)

    def test_without_oref_no_subset_keys(self):
        samples = [make_sample(START_MINUTES, 120.0, {"30": 125.0})]
        evaluation = train_dynamics.evaluate_heldout(StubForecaster(), samples, None)
        self.assertNotIn("oref", evaluation)
        self.assertNotIn("candidate_oref_subset", evaluation)
        self.assertEqual(evaluation["candidate"]["30"]["n"], 1)


if __name__ == "__main__":
    unittest.main()
