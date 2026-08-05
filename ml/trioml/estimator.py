"""StateEstimator prototype: CGM-lag compensation (plan §2.1).

Interstitial CGM readings reflect blood glucose ~10-15 minutes ago. The
estimator is a small 2-state Kalman filter over [glucose_now, trend] where the
measurement model observes the *delayed* value:

    observation ≈ glucose_now − lag · trend

so each new reading updates an estimate of glucose *now*, not glucose
lag-minutes-ago. The dynamics model will later add known insulin activity and
carb absorption as control inputs; this prototype establishes the filter, the
API, and the QC hooks so it can be validated against exported data (compare
estimates at time t with the reading that arrives at t + lag).

Pure stdlib on purpose: the same arithmetic ports 1:1 to Swift for on-device
inference, and golden-file tests can pin both sides to identical outputs.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

DEFAULT_LAG_MINUTES = 10.0

# Process noise: how much true glucose / trend can drift per minute.
GLUCOSE_PROCESS_NOISE = 0.5   # (mg/dL)^2 per min
TREND_PROCESS_NOISE = 0.05    # (mg/dL/min)^2 per min
# CGM measurement noise (σ ≈ 7 mg/dL for modern sensors mid-range).
MEASUREMENT_NOISE = 49.0      # (mg/dL)^2
# Trend mean-reversion per minute (glucose does not trend forever). Tuned on
# synthetic ramp + sinusoid sweeps: 0.98 under-tracks sustained trends (ramp
# error ~10 of 20 mg/dL lag); 0.999 over-trusts trend into direction changes;
# 0.995 recovers ~85% of the lag while still beating raw readings on turns.
TREND_DECAY_PER_MINUTE = 0.995

# QC limits.
MAX_PLAUSIBLE_DELTA_PER_5MIN = 30.0  # mg/dL; beyond this → suspect reading
MAX_BRIDGEABLE_GAP_MINUTES = 15.0    # beyond this the estimate is stale


@dataclass
class Estimate:
    glucose_now: float          # estimated *current* blood glucose, mg/dL
    trend_per_minute: float     # estimated rate of change, mg/dL/min
    variance: float             # variance of glucose_now estimate
    reading_suspect: bool       # last reading failed QC (implausible jump)
    stale: bool                 # gap since last reading exceeds bridgeable window


@dataclass
class StateEstimator:
    lag_minutes: float = DEFAULT_LAG_MINUTES
    # State [g, t]: current glucose and trend.
    _g: float = 0.0
    _t: float = 0.0
    # Covariance [[pgg, pgt], [pgt, ptt]].
    _pgg: float = 1e6
    _pgt: float = 0.0
    _ptt: float = 1.0
    _last_time: float | None = field(default=None)
    _last_reading: float | None = field(default=None)

    def update(self, time_minutes: float, reading: float) -> Estimate:
        """Feed one newly delivered CGM reading; returns the current estimate."""
        suspect = False
        stale = False

        if self._last_time is None:
            # Initialize at the reading, projected forward by the lag with zero trend.
            self._g = reading
            self._t = 0.0
            self._pgg = MEASUREMENT_NOISE
            self._pgt = 0.0
            self._ptt = 0.25
        else:
            dt = time_minutes - self._last_time
            if dt <= 0:
                # Duplicate or out-of-order delivery: ignore, return current state.
                return self._estimate(suspect=False, stale=False)
            stale = dt > MAX_BRIDGEABLE_GAP_MINUTES

            if self._last_reading is not None:
                delta_per_5 = abs(reading - self._last_reading) / dt * 5.0
                suspect = delta_per_5 > MAX_PLAUSIBLE_DELTA_PER_5MIN

            self._predict(dt)

            if not suspect:
                self._correct(reading)
            # A suspect reading (compression low, calibration jump) still advances
            # time via _predict but does not move the state; the caller decides
            # whether to fall back (§2.6).

        self._last_time = time_minutes
        self._last_reading = reading
        return self._estimate(suspect=suspect, stale=stale)

    def project(self, minutes_ahead: float) -> float:
        """Dead-reckoned glucose `minutes_ahead` from the current estimate."""
        return self._g + self._t * minutes_ahead

    # --- Kalman internals -------------------------------------------------

    def _predict(self, dt: float) -> None:
        decay = TREND_DECAY_PER_MINUTE ** dt
        # g' = g + t·dt ; t' = decay·t
        self._g = self._g + self._t * dt
        self._t = self._t * decay
        # P' = F P Fᵀ + Q with F = [[1, dt], [0, decay]]
        pgg = self._pgg + dt * (2 * self._pgt + dt * self._ptt)
        pgt = decay * (self._pgt + dt * self._ptt)
        ptt = decay * decay * self._ptt
        self._pgg = pgg + GLUCOSE_PROCESS_NOISE * dt
        self._pgt = pgt
        self._ptt = ptt + TREND_PROCESS_NOISE * dt

    def _correct(self, reading: float) -> None:
        # H = [1, -lag]: the reading observes glucose lag-minutes ago.
        lag = self.lag_minutes
        predicted_reading = self._g - lag * self._t
        innovation = reading - predicted_reading
        # S = H P Hᵀ + R
        s = self._pgg - 2 * lag * self._pgt + lag * lag * self._ptt + MEASUREMENT_NOISE
        # K = P Hᵀ / S
        kg = (self._pgg - lag * self._pgt) / s
        kt = (self._pgt - lag * self._ptt) / s
        self._g += kg * innovation
        self._t += kt * innovation
        # Joseph-free covariance update: P = (I − K H) P
        pgg = self._pgg
        pgt = self._pgt
        ptt = self._ptt
        self._pgg = (1 - kg) * pgg + kg * lag * pgt
        self._pgt = (1 - kg) * pgt + kg * lag * ptt
        self._ptt = -kt * pgt + (1 + kt * lag) * ptt

    def _estimate(self, suspect: bool, stale: bool) -> Estimate:
        return Estimate(
            glucose_now=self._g,
            trend_per_minute=self._t,
            variance=self._pgg,
            reading_suspect=suspect,
            stale=stale,
        )


def replay(readings: list[tuple[float, float]], lag_minutes: float = DEFAULT_LAG_MINUTES) -> list[Estimate]:
    """Runs the estimator over (time_minutes, reading) pairs, returning all estimates."""
    estimator = StateEstimator(lag_minutes=lag_minutes)
    return [estimator.update(t, value) for t, value in readings]


def lag_compensation_error(
    true_series: list[tuple[float, float]],
    estimates: list[Estimate],
) -> float:
    """RMSE of estimates vs. the true current values (for synthetic validation)."""
    if len(true_series) != len(estimates):
        raise ValueError("series length mismatch")
    errors = [est.glucose_now - true for (_, true), est in zip(true_series, estimates)]
    # Skip the warm-up half where the filter is still converging.
    tail = errors[len(errors) // 2:]
    return math.sqrt(sum(e * e for e in tail) / len(tail))
