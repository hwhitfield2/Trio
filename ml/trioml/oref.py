"""oref's exported predBGs as the champion forecaster (plan Phase 2 gate).

Newer exports carry each determination's ``predBGs`` — oref's own forecast
curves in mg/dL at 5-min steps from the determination time:

- ``iob``: insulin-only decay
- ``zt``:  zero-temp counterfactual (a safety bound, not the expected path)
- ``cob``: announced-carb absorption scenario
- ``uam``: unannounced-meal detection scenario

The Phase 2 gate compares the dynamics model against what oref actually
predicted, like-for-like. The "scenario" forecast mirrors which absorption
model oref considers active: the carb curve while COB is positive, else UAM
when present, else insulin-only. ``zt`` is deliberately never the scenario.
"""

from __future__ import annotations

import bisect

from . import schema
from .dataset import _parse_iso

SCENARIO_PRIORITY = ("uam", "iob")
# A determination speaks for a 5-min frame anchor if it happened within this
# window of it (determinations run on CGM delivery, so normally well inside).
MATCH_TOLERANCE_MINUTES = 5.0


def determination_predictions(events: list[dict]) -> list[tuple[float, dict, float]]:
    """(epoch_minutes, predBGs, cob) for determinations that carry predBGs."""
    out = []
    for event in events:
        if event.get("type") == "determination" and event.get("predBGs"):
            out.append((
                _parse_iso(event["date"]),
                event["predBGs"],
                float(event.get("cob") or 0.0),
            ))
    out.sort(key=lambda item: item[0])
    return out


class OrefForecasts:
    """Point lookups into oref's stored forecasts, aligned to frame anchors."""

    def __init__(self, events: list[dict]):
        self._determinations = determination_predictions(events)
        self._times = [t for t, _, _ in self._determinations]

    def __len__(self) -> int:
        return len(self._determinations)

    def at(self, anchor_minutes: float, horizon_minutes: int, curve: str | None = None) -> float | None:
        """oref's forecast for anchor + horizon, from the nearest determination.

        ``curve`` picks one predBGs curve; None picks the active scenario.
        Returns None when no determination is close enough or the curve does
        not reach the horizon — the caller must score only what oref actually
        predicted.
        """
        index = bisect.bisect_left(self._times, anchor_minutes)
        best = None
        for candidate in (index - 1, index):
            if 0 <= candidate < len(self._times):
                distance = abs(self._times[candidate] - anchor_minutes)
                if distance <= MATCH_TOLERANCE_MINUTES and (best is None or distance < best[0]):
                    best = (distance, candidate)
        if best is None:
            return None
        time, pred_bgs, cob = self._determinations[best[1]]

        if curve is None:
            if cob > 0 and "cob" in pred_bgs:
                curve = "cob"
            else:
                curve = next((c for c in SCENARIO_PRIORITY if c in pred_bgs), None)
        values = pred_bgs.get(curve) if curve else None
        if not values:
            return None
        step = round((anchor_minutes + horizon_minutes - time) / schema.FRAME_INTERVAL_MINUTES)
        if not 0 <= step < len(values):
            return None
        return float(values[step])
