"""Raw export events → 5-minute training frames.

This is the single place feature alignment lives (the Swift inference side
mirrors it against the same schema version). A frame is one 5-minute grid slot:

    {
        "t": epoch_minutes,
        "glucose": mg/dL at slot (nearest reading within the slot) or None,
        "carbs": grams entered during the slot,
        "bolus": units delivered during the slot (SMB + manual),
        "temp_basal_rate": U/hr active at slot end (None if no temp),
        "iob": bolus IOB at slot end,
        "labels": {"30": bg, "60": bg, "120": bg}  # future glucose, when known
    }
"""

from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from . import insulin, schema


def _parse_iso(ts: str) -> float:
    """ISO-8601 → epoch minutes."""
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt.timestamp() / 60.0


def load_events(path: str | Path) -> list[dict]:
    """Reads a JSONL export, validates the header, returns event dicts."""
    events: list[dict] = []
    with open(path) as handle:
        for index, line in enumerate(handle):
            line = line.strip()
            if not line:
                continue
            event = json.loads(line)
            if index == 0:
                schema.validate_header(event)
                continue
            if event.get("type") not in schema.EVENT_TYPES:
                raise schema.SchemaError(f"unknown event type: {event.get('type')!r}")
            events.append(event)
    return events


def build_frames(
    events: list[dict],
    dia_minutes: float = insulin.DEFAULT_DIA_MINUTES,
    peak_minutes: float = insulin.DEFAULT_PEAK_MINUTES,
) -> list[dict]:
    """Aligns events onto the 5-minute grid and attaches labels."""
    interval = schema.FRAME_INTERVAL_MINUTES

    glucose: list[tuple[float, int]] = []
    carbs: list[tuple[float, float]] = []
    boluses: list[tuple[float, float]] = []
    temp_basals: list[tuple[float, float, int]] = []  # (t, rate, duration_min)

    for event in events:
        kind = event["type"]
        t = _parse_iso(event["date"])
        if kind == "glucose":
            value = event["glucose"]
            if schema.GLUCOSE_MIN <= value <= schema.GLUCOSE_MAX and not event.get("isManual"):
                glucose.append((t, value))
        elif kind == "carbs":
            if not event.get("isFPU"):
                carbs.append((t, event["carbs"]))
        elif kind == "pump":
            if event.get("bolusAmount") is not None:
                boluses.append((t, float(event["bolusAmount"])))
            if event.get("tempBasalRate") is not None:
                temp_basals.append((
                    t,
                    float(event["tempBasalRate"]),
                    int(event.get("tempBasalDurationMinutes") or 0),
                ))

    if not glucose:
        return []

    glucose.sort()
    carbs.sort()
    boluses.sort()
    temp_basals.sort()

    start = _grid(glucose[0][0], interval)
    end = _grid(glucose[-1][0], interval)

    glucose_by_slot: dict[float, int] = {}
    for t, value in glucose:
        # Last reading in a slot wins (dedup of backfill re-deliveries).
        glucose_by_slot[_grid(t, interval)] = value

    frames: list[dict] = []
    slot = start
    while slot <= end:
        slot_end = slot + interval
        frame_carbs = sum(g for t, g in carbs if slot <= t < slot_end)
        frame_bolus = sum(u for t, u in boluses if slot <= t < slot_end)
        active_temp = _active_temp_basal(temp_basals, slot_end)
        frames.append({
            "t": slot,
            "glucose": glucose_by_slot.get(slot),
            "carbs": frame_carbs,
            "bolus": frame_bolus,
            "temp_basal_rate": active_temp,
            "iob": insulin.iob_from_boluses(slot_end, boluses, dia_minutes, peak_minutes),
            "labels": {},
        })
        slot += interval

    for frame in frames:
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            label = glucose_by_slot.get(frame["t"] + horizon)
            if label is not None:
                frame["labels"][str(horizon)] = label

    return frames


def _grid(t: float, interval: int) -> float:
    return float(int(t // interval) * interval)


def _active_temp_basal(temp_basals: list[tuple[float, float, int]], at: float) -> float | None:
    """Rate of the most recent temp basal still running at `at`, else None."""
    active = None
    for t, rate, duration in temp_basals:
        if t <= at < t + duration:
            active = rate
        elif t > at:
            break
    return active
