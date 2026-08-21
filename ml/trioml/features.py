"""Frames → model-ready samples for the dynamics model (plan §2.2).

A sample is anchored at one 5-minute frame ("now") and carries:

- ``history``: HISTORY_STEPS × HISTORY_CHANNELS, oldest step first — the last
  6 h of glucose, delivery, IOB, and time-of-day context;
- ``plan``: HORIZON_STEPS × PLAN_CHANNELS — insulin delivery per future slot.
  During training this is the *actual* delivered insulin (the model learns
  glucose conditioned on what was really given); at controller time the same
  channels carry a *candidate* plan;
- ``target``/``target_mask``: glucose delta from "now" at each future step,
  masked where no reading exists (CGM gaps are masked, never interpolated
  into labels);
- ``labels``: absolute future glucose at the gate horizons (30/60/120 min).

Stdlib on purpose: only ``trioml.model`` needs torch, and the featurization
must stay portable to Swift for on-device inference with golden-file parity.
"""

from __future__ import annotations

import math

from . import schema

HISTORY_STEPS = schema.HISTORY_MINUTES // schema.FRAME_INTERVAL_MINUTES     # 72
HORIZON_STEPS = schema.HORIZON_MINUTES // schema.FRAME_INTERVAL_MINUTES     # 48

HISTORY_CHANNELS = (
    "glucose",        # normalized; missing slots linearly interpolated
    "glucose_missing",  # 1.0 where the slot had no reading (so the model knows)
    "carbs",          # grams entered during the slot / CARB_SCALE
    "bolus",          # units delivered during the slot
    "iob",            # bolus IOB at slot end / IOB_SCALE
    "temp_basal_rate",  # U/hr (0 when no temp is running)
    "tod_sin",        # time-of-day encoding
    "tod_cos",
)
PLAN_CHANNELS = (
    "bolus",          # units per future slot
    "temp_basal_rate",  # U/hr per future slot
)

# Normalization: keeps every channel roughly O(1) without data-dependent
# statistics, so Python training and Swift inference cannot drift apart.
GLUCOSE_CENTER = 120.0
GLUCOSE_SCALE = 60.0
CARB_SCALE = 10.0
IOB_SCALE = 2.0

# A history window is usable only if its CGM gaps are bridgeable: no missing
# run longer than this (matches the estimator's MAX_BRIDGEABLE_GAP_MINUTES).
MAX_MISSING_RUN_STEPS = 3

MINUTES_PER_DAY = 24 * 60


def normalize_glucose(value: float) -> float:
    return (value - GLUCOSE_CENTER) / GLUCOSE_SCALE


def denormalize_glucose(value: float) -> float:
    return value * GLUCOSE_SCALE + GLUCOSE_CENTER


def build_samples(frames: list[dict]) -> list[dict]:
    """Every frame with glucose "now" and a usable 6-h history becomes a sample."""
    samples: list[dict] = []
    for index in range(HISTORY_STEPS - 1, len(frames)):
        now = frames[index]
        if now.get("glucose") is None:
            continue
        window = frames[index - HISTORY_STEPS + 1: index + 1]
        glucose_series = _interpolated_glucose([f.get("glucose") for f in window])
        if glucose_series is None:
            continue

        history: list[list[float]] = []
        for step, frame in enumerate(window):
            minute_of_day = frame["t"] % MINUTES_PER_DAY
            angle = 2 * math.pi * minute_of_day / MINUTES_PER_DAY
            history.append([
                normalize_glucose(glucose_series[step]),
                1.0 if frame.get("glucose") is None else 0.0,
                float(frame.get("carbs") or 0.0) / CARB_SCALE,
                float(frame.get("bolus") or 0.0),
                float(frame.get("iob") or 0.0) / IOB_SCALE,
                float(frame.get("temp_basal_rate") or 0.0),
                math.sin(angle),
                math.cos(angle),
            ])

        plan: list[list[float]] = []
        target: list[float] = []
        target_mask: list[float] = []
        now_glucose = float(now["glucose"])
        for step in range(1, HORIZON_STEPS + 1):
            future = frames[index + step] if index + step < len(frames) else None
            plan.append([
                float((future or {}).get("bolus") or 0.0),
                float((future or {}).get("temp_basal_rate") or 0.0),
            ])
            future_glucose = (future or {}).get("glucose")
            if future_glucose is None:
                target.append(0.0)
                target_mask.append(0.0)
            else:
                target.append((float(future_glucose) - now_glucose) / GLUCOSE_SCALE)
                target_mask.append(1.0)

        if not any(target_mask):
            continue

        samples.append({
            "t": now["t"],
            "now_glucose": now_glucose,
            "history": history,
            "plan": plan,
            "target": target,
            "target_mask": target_mask,
            "labels": dict(now["labels"]),
        })
    return samples


def _interpolated_glucose(values: list[float | None]) -> list[float] | None:
    """Linear interpolation across short gaps; None if the window is unusable.

    Unusable: missing endpoints (nothing to anchor the interpolation) or any
    missing run longer than MAX_MISSING_RUN_STEPS.
    """
    if values[0] is None or values[-1] is None:
        return None
    result = [float(v) if v is not None else None for v in values]
    run_start = None
    for i, value in enumerate(result):
        if value is None:
            if run_start is None:
                run_start = i
            continue
        if run_start is not None:
            run_length = i - run_start
            if run_length > MAX_MISSING_RUN_STEPS:
                return None
            left = result[run_start - 1]
            for j in range(run_start, i):
                fraction = (j - run_start + 1) / (run_length + 1)
                result[j] = left + (value - left) * fraction
            run_start = None
    return result  # type: ignore[return-value]


def horizon_step(horizon_minutes: int) -> int:
    """Index into the target/plan vectors for a gate horizon."""
    step = horizon_minutes // schema.FRAME_INTERVAL_MINUTES - 1
    if not 0 <= step < HORIZON_STEPS:
        raise ValueError(f"horizon {horizon_minutes} min outside the {schema.HORIZON_MINUTES}-min window")
    return step
