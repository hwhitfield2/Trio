import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from trioml import dataset, merge, nightscout


class NightscoutConverterTests(unittest.TestCase):
    def test_entries_convert_to_glucose_events(self):
        entries = [
            {"type": "sgv", "sgv": 132, "dateString": "2026-01-01T00:00:00Z", "direction": "Flat"},
            {"type": "cal", "dateString": "2026-01-01T00:05:00Z"},  # non-sgv skipped
            {"type": "sgv", "dateString": "2026-01-01T00:10:00Z"},  # missing sgv skipped
        ]
        events = nightscout.events_from_entries(entries)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "glucose")
        self.assertEqual(events[0]["glucose"], 132)
        self.assertEqual(events[0]["direction"], "Flat")

    def test_treatments_convert_carbs_boluses_tempbasals(self):
        treatments = [
            {"eventType": "Meal Bolus", "created_at": "2026-01-01T12:00:00Z", "carbs": 45, "insulin": 3.5},
            {"eventType": "SMB", "created_at": "2026-01-01T12:30:00Z", "insulin": 0.4},
            {"eventType": "Temp Basal", "created_at": "2026-01-01T12:35:00Z", "rate": 2.1, "duration": 30},
            {"eventType": "Temp Target", "created_at": "2026-01-01T13:00:00Z"},  # no data → skipped
        ]
        events = nightscout.events_from_treatments(treatments)
        kinds = [(e["type"], e.get("eventType")) for e in events]
        self.assertIn(("carbs", None), [(k, None) if k == "carbs" else (k, t) for k, t in kinds])
        self.assertEqual(sum(1 for e in events if e["type"] == "carbs"), 1)
        boluses = [e for e in events if e["type"] == "pump" and e["bolusAmount"]]
        self.assertEqual(len(boluses), 2)
        self.assertTrue(any(e["isSMB"] for e in boluses))
        temps = [e for e in events if e["type"] == "pump" and e["tempBasalRate"] is not None]
        self.assertEqual(len(temps), 1)
        self.assertEqual(temps[0]["tempBasalDurationMinutes"], 30)

    def test_converted_events_feed_build_frames(self):
        entries = [
            {"type": "sgv", "sgv": 120 + i, "dateString": f"2026-01-01T00:{5 * i:02d}:00Z"}
            for i in range(10)
        ]
        treatments = [{"eventType": "Meal Bolus", "created_at": "2026-01-01T00:01:00Z", "carbs": 30, "insulin": 2.0}]
        events = nightscout.events_from_entries(entries) + nightscout.events_from_treatments(treatments)
        frames = dataset.build_frames(events)
        self.assertEqual(len(frames), 10)
        self.assertEqual(frames[0]["carbs"], 30.0)
        self.assertEqual(frames[0]["bolus"], 2.0)


class MergeTests(unittest.TestCase):
    def test_overlapping_sources_dedupe(self):
        app_export = [
            {"type": "glucose", "date": "2026-01-01T00:00:00Z", "glucose": 120, "isManual": False},
            {"type": "glucose", "date": "2026-01-01T00:05:00Z", "glucose": 124, "isManual": False},
        ]
        ns = [
            {"type": "glucose", "date": "2026-01-01T00:05:00Z", "glucose": 124},  # duplicate
            {"type": "glucose", "date": "2026-01-01T00:10:00Z", "glucose": 128},  # new
        ]
        merged = merge.merge_events(app_export, ns)
        self.assertEqual(len(merged), 3)
        # First source wins for the duplicate: the richer app-export doc survives.
        dup = [e for e in merged if e["date"] == "2026-01-01T00:05:00Z"][0]
        self.assertIn("isManual", dup)

    def test_merge_is_idempotent_and_sorted(self):
        source = [
            {"type": "glucose", "date": "2026-01-01T00:10:00Z", "glucose": 128},
            {"type": "glucose", "date": "2026-01-01T00:00:00Z", "glucose": 120},
        ]
        once = merge.merge_events(source)
        twice = merge.merge_events(once, source)
        self.assertEqual(once, twice)
        self.assertEqual([e["date"] for e in twice], sorted(e["date"] for e in twice))

    def test_same_timestamp_different_values_both_kept(self):
        source = [
            {"type": "pump", "date": "2026-01-01T00:00:00Z", "bolusAmount": 1.0, "tempBasalRate": None},
            {"type": "pump", "date": "2026-01-01T00:00:00Z", "bolusAmount": None, "tempBasalRate": 2.0},
        ]
        merged = merge.merge_events(source)
        self.assertEqual(len(merged), 2)


if __name__ == "__main__":
    unittest.main()
