"""Naive predictors every candidate model must beat.

The real bar is oref's own stored predBGs (exported as determination events);
these two are the sanity floor beneath that.
"""

from __future__ import annotations


def last_value(history: list[float], horizon_minutes: int) -> float:
    """Predicts glucose stays where it is."""
    if not history:
        raise ValueError("empty history")
    return history[-1]


def linear_trend(
    history: list[float],
    horizon_minutes: int,
    interval_minutes: int = 5,
    trend_window: int = 4,
) -> float:
    """Extrapolates the recent slope, clamped to a plausible band."""
    if not history:
        raise ValueError("empty history")
    if len(history) < 2:
        return history[-1]
    window = history[-trend_window:]
    slope_per_interval = (window[-1] - window[0]) / (len(window) - 1)
    steps = horizon_minutes / interval_minutes
    predicted = history[-1] + slope_per_interval * steps
    return max(20.0, min(500.0, predicted))
