import json
import sys
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import dataset, schema

START = datetime(2026, 1, 1, 0, 0, tzinfo=timezone.utc)


def iso(minutes: float) -> str:
    return (START + timedelta(minutes=minutes)).isoformat()


def make_export(events: list[dict], header_version: int = schema.EXPORT_SCHEMA_VERSION) -> str:
    lines = [json.dumps({"type": "header", "schemaVersion": header_version, "exportedAt": iso(0), "daysBack": 1})]
    lines += [json.dumps(e) for e in events]
    handle = tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False)
    handle.write("\n".join(lines) + "\n")
    handle.close()
    return handle.name


class LoadEventsTests(unittest.TestCase):
    def test_header_version_mismatch_is_hard_error(self):
        path = make_export([], header_version=99)
        with self.assertRaises(schema.SchemaError):
            dataset.load_events(path)

    def test_unknown_event_type_is_hard_error(self):
        path = make_export([{"type": "mystery", "date": iso(0)}])
        with self.assertRaises(schema.SchemaError):
            dataset.load_events(path)

    def test_loads_valid_events(self):
        path = make_export([{"type": "glucose", "date": iso(0), "glucose": 120, "isManual": False}])
        events = dataset.load_events(path)
        self.assertEqual(len(events), 1)


class BuildFramesTests(unittest.TestCase):
    def _glucose_series(self, count: int, value: int = 120) -> list[dict]:
        return [
            {"type": "glucose", "date": iso(5 * i), "glucose": value + i, "isManual": False}
            for i in range(count)
        ]

    def test_frames_on_five_minute_grid(self):
        frames = dataset.build_frames(self._glucose_series(12))
        self.assertEqual(len(frames), 12)
        for earlier, later in zip(frames, frames[1:]):
            self.assertEqual(later["t"] - earlier["t"], schema.FRAME_INTERVAL_MINUTES)

    def test_labels_attached_at_horizons(self):
        frames = dataset.build_frames(self._glucose_series(30))
        first = frames[0]
        self.assertIn("30", first["labels"])
        self.assertIn("60", first["labels"])
        self.assertIn("120", first["labels"])
        # Label equals the reading 6 slots later (value increments by slot).
        self.assertEqual(first["labels"]["30"], first["glucose"] + 6)

    def test_carbs_and_bolus_summed_into_slot(self):
        events = self._glucose_series(4) + [
            {"type": "carbs", "date": iso(1), "carbs": 30.0, "isFPU": False},
            {"type": "carbs", "date": iso(2), "carbs": 10.0, "isFPU": False},
            {"type": "pump", "date": iso(1), "bolusAmount": 1.5},
        ]
        frames = dataset.build_frames(events)
        self.assertEqual(frames[0]["carbs"], 40.0)
        self.assertEqual(frames[0]["bolus"], 1.5)
        self.assertGreater(frames[0]["iob"], 1.4)  # bolus just delivered, nearly all on board

    def test_manual_and_implausible_glucose_excluded(self):
        events = [
            {"type": "glucose", "date": iso(0), "glucose": 120, "isManual": False},
            {"type": "glucose", "date": iso(5), "glucose": 600, "isManual": False},  # implausible
            {"type": "glucose", "date": iso(10), "glucose": 130, "isManual": True},  # manual
            {"type": "glucose", "date": iso(15), "glucose": 125, "isManual": False},
        ]
        frames = dataset.build_frames(events)
        values = [f["glucose"] for f in frames]
        self.assertNotIn(600, values)
        self.assertNotIn(130, values)

    def test_temp_basal_active_within_duration_only(self):
        events = self._glucose_series(10) + [
            {"type": "pump", "date": iso(0), "tempBasalRate": 2.0, "tempBasalDurationMinutes": 12},
        ]
        frames = dataset.build_frames(events)
        self.assertEqual(frames[0]["temp_basal_rate"], 2.0)   # active at slot end 5
        self.assertEqual(frames[1]["temp_basal_rate"], 2.0)   # active at slot end 10
        self.assertIsNone(frames[2]["temp_basal_rate"])       # expired at slot end 15

    def test_empty_events_give_empty_frames(self):
        self.assertEqual(dataset.build_frames([]), [])


if __name__ == "__main__":
    unittest.main()
