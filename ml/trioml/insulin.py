"""Exponential insulin activity / IOB curves.

The standard exponential model used by oref and Loop (Dragan Maksimovic's
formulation): given DIA and peak-activity time, activity is

    A(t) = (S / tau^2) * t * (1 - t/td) * exp(-t/tau)

and IOB is its complementary integral. `iob_fraction(t)` is the fraction of a
unit bolus still active `t` minutes after delivery.
"""

from __future__ import annotations

import math

DEFAULT_DIA_MINUTES = 5 * 60
DEFAULT_PEAK_MINUTES = 75  # rapid-acting default (Preferences.insulinPeakTime)


def _curve_constants(dia_minutes: float, peak_minutes: float) -> tuple[float, float, float]:
    td = float(dia_minutes)
    tp = float(peak_minutes)
    if not 0 < tp < td:
        raise ValueError(f"peak {tp} must be in (0, dia {td})")
    tau = tp * (1 - tp / td) / (1 - 2 * tp / td)
    a = 2 * tau / td
    s = 1 / (1 - a + (1 + a) * math.exp(-td / tau))
    return tau, a, s


def iob_fraction(
    minutes_since_delivery: float,
    dia_minutes: float = DEFAULT_DIA_MINUTES,
    peak_minutes: float = DEFAULT_PEAK_MINUTES,
) -> float:
    """Fraction of a unit bolus still on board after `minutes_since_delivery`."""
    t = float(minutes_since_delivery)
    if t <= 0:
        return 1.0
    td = float(dia_minutes)
    if t >= td:
        return 0.0
    tau, a, s = _curve_constants(td, peak_minutes)
    iob = 1 - s * (1 - a) * (
        (t * t / (tau * td * (1 - a)) - t / tau - 1) * math.exp(-t / tau) + 1
    )
    return min(max(iob, 0.0), 1.0)


def activity_fraction(
    minutes_since_delivery: float,
    dia_minutes: float = DEFAULT_DIA_MINUTES,
    peak_minutes: float = DEFAULT_PEAK_MINUTES,
) -> float:
    """Instantaneous activity (per minute) of a unit bolus."""
    t = float(minutes_since_delivery)
    td = float(dia_minutes)
    if t <= 0 or t >= td:
        return 0.0
    tau, _a, s = _curve_constants(td, peak_minutes)
    return (s / (tau * tau)) * t * (1 - t / td) * math.exp(-t / tau)


def iob_from_boluses(
    now_minutes: float,
    boluses: list[tuple[float, float]],
    dia_minutes: float = DEFAULT_DIA_MINUTES,
    peak_minutes: float = DEFAULT_PEAK_MINUTES,
) -> float:
    """Total IOB at `now_minutes` from (time_minutes, units) bolus events."""
    return sum(
        units * iob_fraction(now_minutes - t, dia_minutes, peak_minutes)
        for t, units in boluses
        if t <= now_minutes
    )
