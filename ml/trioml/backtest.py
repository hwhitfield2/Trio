"""Frame-by-frame replay of a predictor over historical frames.

A predictor is `fn(history: list[float], horizon_minutes: int) -> float` where
`history` is the glucose sequence up to and including "now". The harness feeds
it every frame that has a label and reports per-horizon metrics, overall and in
the low-glucose region — the plan's gate requires that low-region performance
never degrades even when overall RMSE improves.
"""

from __future__ import annotations

import math
from typing import Callable

from . import schema

Predictor = Callable[[list[float], int], float]


def run_backtest(
    frames: list[dict],
    predictor: Predictor,
    horizons: tuple[int, ...] = schema.LABEL_HORIZONS_MINUTES,
    min_history: int = 6,
) -> dict:
    """Returns {"horizon": {"rmse", "mae", "n", "low_rmse", "low_n"}, ...}."""
    metrics: dict[str, dict] = {}
    for horizon in horizons:
        errors: list[float] = []
        low_errors: list[float] = []
        history: list[float] = []
        for frame in frames:
            glucose = frame.get("glucose")
            if glucose is None:
                continue
            history.append(float(glucose))
            if len(history) < min_history:
                continue
            label = frame["labels"].get(str(horizon))
            if label is None:
                continue
            predicted = predictor(list(history), horizon)
            error = predicted - float(label)
            errors.append(error)
            if float(label) < schema.LOW_REGION_THRESHOLD:
                low_errors.append(error)
        metrics[str(horizon)] = {
            "rmse": _rmse(errors),
            "mae": _mean(list(map(abs, errors))),
            "n": len(errors),
            "low_rmse": _rmse(low_errors),
            "low_n": len(low_errors),
        }
    return metrics


def metrics_from_predictions(
    records: list[dict],
    horizons: tuple[int, ...] = schema.LABEL_HORIZONS_MINUTES,
) -> dict:
    """Same metrics shape as run_backtest, from precomputed predictions.

    For predictors that need more than a glucose history (the dynamics model
    consumes full feature samples): records are
    ``{"horizon": minutes, "predicted": mg/dL, "actual": mg/dL}``, so candidate
    and champion can be scored on identical (frame, horizon) pairs — the gates
    require like-for-like comparison.
    """
    metrics: dict[str, dict] = {}
    for horizon in horizons:
        errors: list[float] = []
        low_errors: list[float] = []
        for record in records:
            if record["horizon"] != horizon:
                continue
            error = record["predicted"] - record["actual"]
            errors.append(error)
            if record["actual"] < schema.LOW_REGION_THRESHOLD:
                low_errors.append(error)
        metrics[str(horizon)] = {
            "rmse": _rmse(errors),
            "mae": _mean(list(map(abs, errors))),
            "n": len(errors),
            "low_rmse": _rmse(low_errors),
            "low_n": len(low_errors),
        }
    return metrics


def _rmse(errors: list[float]) -> float | None:
    if not errors:
        return None
    return math.sqrt(sum(e * e for e in errors) / len(errors))


def _mean(values: list[float]) -> float | None:
    if not values:
        return None
    return sum(values) / len(values)
