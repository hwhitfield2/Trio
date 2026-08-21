import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import features, schema


def make_frames(count: int, glucose=lambda i: 120.0 + 10 * math.sin(i / 10)) -> list[dict]:
    frames = []
    for i in range(count):
        frames.append({
            "t": float(i * schema.FRAME_INTERVAL_MINUTES),
            "glucose": glucose(i),
            "carbs": 0.0,
            "bolus": 0.0,
            "temp_basal_rate": None,
            "iob": 0.0,
            "labels": {},
        })
    for frame in frames:
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            j = int(frame["t"] // schema.FRAME_INTERVAL_MINUTES) + horizon // schema.FRAME_INTERVAL_MINUTES
            if j < count and frames[j]["glucose"] is not None:
                frame["labels"][str(horizon)] = frames[j]["glucose"]
    return frames


class BuildSamplesTests(unittest.TestCase):
    def test_shapes_and_count(self):
        frames = make_frames(features.HISTORY_STEPS + 10)
        samples = features.build_samples(frames)
        # Anchors run from HISTORY_STEPS-1 to the end; the final frame has no
        # future readings at all, so it cannot be a sample.
        self.assertEqual(len(samples), 10)
        sample = samples[0]
        self.assertEqual(len(sample["history"]), features.HISTORY_STEPS)
        self.assertEqual(len(sample["history"][0]), len(features.HISTORY_CHANNELS))
        self.assertEqual(len(sample["plan"]), features.HORIZON_STEPS)
        self.assertEqual(len(sample["plan"][0]), len(features.PLAN_CHANNELS))
        self.assertEqual(len(sample["target"]), features.HORIZON_STEPS)
        self.assertEqual(len(sample["target_mask"]), features.HORIZON_STEPS)

    def test_delta_targets_match_labels(self):
        frames = make_frames(features.HISTORY_STEPS + 48)
        sample = features.build_samples(frames)[0]
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            if str(horizon) not in sample["labels"]:
                continue
            step = features.horizon_step(horizon)
            self.assertEqual(sample["target_mask"][step], 1.0)
            reconstructed = sample["now_glucose"] + sample["target"][step] * features.GLUCOSE_SCALE
            self.assertAlmostEqual(reconstructed, sample["labels"][str(horizon)], places=6)

    def test_short_gap_interpolated_and_flagged(self):
        frames = make_frames(features.HISTORY_STEPS + 5, glucose=lambda i: 100.0 + i)
        gap = features.HISTORY_STEPS // 2
        frames[gap]["glucose"] = None
        samples = features.build_samples(frames)
        self.assertTrue(samples)
        history = samples[0]["history"]
        self.assertEqual(history[gap][1], 1.0)  # missing flag
        interpolated = features.denormalize_glucose(history[gap][0])
        self.assertAlmostEqual(interpolated, 100.0 + gap, places=6)

    def test_long_gap_drops_window(self):
        frames = make_frames(features.HISTORY_STEPS)
        for i in range(30, 30 + features.MAX_MISSING_RUN_STEPS + 1):
            frames[i]["glucose"] = None
        self.assertEqual(features.build_samples(frames), [])

    def test_future_gap_masks_target(self):
        frames = make_frames(features.HISTORY_STEPS + 12)
        missing_index = features.HISTORY_STEPS + 3
        frames[missing_index]["glucose"] = None
        sample = features.build_samples(frames)[0]
        self.assertEqual(sample["target_mask"][3], 0.0)
        self.assertEqual(sample["target"][3], 0.0)
        self.assertEqual(sample["target_mask"][2], 1.0)

    def test_plan_carries_future_insulin(self):
        frames = make_frames(features.HISTORY_STEPS + 10)
        frames[features.HISTORY_STEPS + 4]["bolus"] = 1.5
        frames[features.HISTORY_STEPS + 4]["temp_basal_rate"] = 0.8
        sample = features.build_samples(frames)[0]
        self.assertEqual(sample["plan"][4], [1.5, 0.8])
        self.assertEqual(sample["plan"][3], [0.0, 0.0])

    def test_no_sample_without_current_glucose(self):
        frames = make_frames(features.HISTORY_STEPS + 6)
        missing = features.HISTORY_STEPS + 2
        frames[missing]["glucose"] = None
        samples = features.build_samples(frames)
        anchor_times = {s["t"] for s in samples}
        self.assertNotIn(frames[missing]["t"], anchor_times)
        self.assertIn(frames[missing - 1]["t"], anchor_times)

    def test_horizon_step_bounds(self):
        self.assertEqual(features.horizon_step(30), 5)
        self.assertEqual(features.horizon_step(schema.HORIZON_MINUTES), features.HORIZON_STEPS - 1)
        with self.assertRaises(ValueError):
            features.horizon_step(schema.HORIZON_MINUTES + 5)


if __name__ == "__main__":
    unittest.main()
