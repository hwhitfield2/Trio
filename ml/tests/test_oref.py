import sys
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import oref

START = datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc)
START_MINUTES = START.timestamp() / 60.0


def iso(minutes: float) -> str:
    return (START + timedelta(minutes=minutes)).isoformat()


def determination(minutes: float, pred_bgs: dict, cob: float = 0.0) -> dict:
    return {"type": "determination", "date": iso(minutes), "predBGs": pred_bgs, "cob": cob}


class OrefForecastsTests(unittest.TestCase):
    def test_ignores_determinations_without_predbgs(self):
        events = [
            {"type": "determination", "date": iso(0), "cob": 0},
            {"type": "glucose", "date": iso(0), "glucose": 120},
        ]
        self.assertEqual(len(oref.OrefForecasts(events)), 0)

    def test_scenario_prefers_cob_only_while_carbs_on_board(self):
        curves = {"iob": [100, 101, 102, 103], "cob": [100, 111, 122, 133], "uam": [100, 106, 112, 118]}
        with_cob = oref.OrefForecasts([determination(0, curves, cob=12)])
        without_cob = oref.OrefForecasts([determination(0, curves, cob=0)])
        self.assertEqual(with_cob.at(START_MINUTES, 10), 122.0)   # cob curve, step 2
        self.assertEqual(without_cob.at(START_MINUTES, 10), 112.0)  # uam curve

    def test_zt_is_never_the_scenario(self):
        forecasts = oref.OrefForecasts([determination(0, {"zt": [100, 90, 80]})])
        self.assertIsNone(forecasts.at(START_MINUTES, 5))
        self.assertEqual(forecasts.at(START_MINUTES, 5, curve="zt"), 90.0)

    def test_alignment_uses_nearest_determination_and_its_own_clock(self):
        # Determination 2 min after the anchor: step math must count from the
        # determination's time, not the anchor's.
        forecasts = oref.OrefForecasts([determination(2, {"iob": [100, 110, 120, 130]})])
        self.assertEqual(forecasts.at(START_MINUTES, 12), 120.0)  # (0 + 12 - 2) / 5 → step 2

    def test_no_determination_within_tolerance(self):
        forecasts = oref.OrefForecasts([determination(20, {"iob": [100, 110]})])
        self.assertIsNone(forecasts.at(START_MINUTES, 30))

    def test_horizon_beyond_curve_returns_none(self):
        forecasts = oref.OrefForecasts([determination(0, {"iob": [100, 110]})])
        self.assertIsNone(forecasts.at(START_MINUTES, 30))

    def test_picks_nearest_of_two_determinations(self):
        forecasts = oref.OrefForecasts([
            determination(-4, {"iob": [90, 91, 92, 93, 94, 95, 96, 97]}),
            determination(1, {"iob": [200, 210, 220, 230]}),
        ])
        self.assertEqual(forecasts.at(START_MINUTES, 11), 220.0)  # (0 + 11 - 1) / 5 → step 2


if __name__ == "__main__":
    unittest.main()
