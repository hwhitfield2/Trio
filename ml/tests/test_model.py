import math
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import features, model

from test_features import make_frames


def synthetic_samples(count: int = 260) -> list[dict]:
    frames = make_frames(
        features.HISTORY_STEPS + count,
        glucose=lambda i: 130.0 + 35 * math.sin(i / 12) + 10 * math.sin(i / 3.1),
    )
    return features.build_samples(frames)


@unittest.skipUnless(model.HAS_TORCH, "torch not installed")
class QuantileTCNTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.samples = synthetic_samples()
        config = model.TrainConfig(epochs=12, patience=12, hidden=16, levels=3)
        cls.trained, cls.report = model.train_model(cls.samples, config)
        cls.forecaster = model.QuantileForecaster(cls.trained)

    def test_report_fields(self):
        self.assertGreater(self.report["parameters"], 0)
        self.assertTrue(math.isfinite(self.report["best_val_pinball"]))
        self.assertGreaterEqual(self.report["best_epoch"], 1)

    def test_quantiles_ordered_by_construction(self):
        prediction = self.forecaster.predict(self.samples[-1])
        for p10, p50, p90 in zip(prediction["p10"], prediction["p50"], prediction["p90"]):
            self.assertLessEqual(p10, p50)
            self.assertLessEqual(p50, p90)

    def test_prediction_shapes_and_bounds(self):
        prediction = self.forecaster.predict(self.samples[0])
        for key in ("p10", "p50", "p90"):
            self.assertEqual(len(prediction[key]), features.HORIZON_STEPS)
            for value in prediction[key]:
                self.assertGreaterEqual(value, 20.0)
                self.assertLessEqual(value, 500.0)
        horizon = self.forecaster.predict_horizon(self.samples[0], 30)
        self.assertEqual(set(horizon), {"p10", "p50", "p90"})

    def test_candidate_plan_changes_prediction_input(self):
        sample = self.samples[-1]
        zero_plan = [[0.0, 0.0] for _ in range(features.HORIZON_STEPS)]
        heavy_plan = [[1.0, 2.0] for _ in range(features.HORIZON_STEPS)]
        base = self.forecaster.predict(sample, plan=zero_plan)
        dosed = self.forecaster.predict(sample, plan=heavy_plan)
        # The plan input must reach the forecast (direction is learned, not asserted).
        self.assertNotEqual(base["p50"], dosed["p50"])

    def test_save_load_roundtrip_and_checksum(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            meta = model.save_model(self.trained, self.report, tmpdir)
            loaded, loaded_meta = model.load_model(tmpdir)
            self.assertEqual(meta["weights_sha256"], loaded_meta["weights_sha256"])
            original = self.forecaster.predict(self.samples[0])
            reloaded = model.QuantileForecaster(loaded).predict(self.samples[0])
            self.assertEqual(original, reloaded)

            weights = Path(tmpdir) / "dynamics_model.pt"
            weights.write_bytes(weights.read_bytes() + b"tampered")
            with self.assertRaises(ValueError):
                model.load_model(tmpdir)

    def test_deterministic_given_seed(self):
        config = model.TrainConfig(epochs=3, patience=3, hidden=16, levels=3)
        first, _ = model.train_model(self.samples, config)
        second, _ = model.train_model(self.samples, config)
        sample = self.samples[0]
        self.assertEqual(
            model.QuantileForecaster(first).predict(sample),
            model.QuantileForecaster(second).predict(sample),
        )

    def test_refuses_tiny_dataset(self):
        with self.assertRaises(ValueError):
            model.train_model(self.samples[:5], model.TrainConfig())


if __name__ == "__main__":
    unittest.main()
