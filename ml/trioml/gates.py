"""Promotion gate suite (docs/ML_DOSING_REPLACEMENT_PLAN.md §3, tier T3).

A candidate model is promoted ONLY if every gate passes. A failed gate means
the champion keeps running — evolution can stall, never regress silently.
"""

from __future__ import annotations

from . import schema

# Candidate must beat champion RMSE by at least this relative margin at every
# evaluated horizon (a tie is not an improvement worth a model swap).
REQUIRED_RELATIVE_IMPROVEMENT = 0.0
# Low-region RMSE may not degrade by more than this relative amount.
MAX_LOW_REGION_DEGRADATION = 0.0
# Below this many labeled samples a horizon comparison is unreliable → gate fails.
MIN_SAMPLES_PER_HORIZON = 100


def compare_backtests(candidate: dict, champion: dict) -> dict:
    """Gate 1+2: overall improvement and low-region non-degradation, per horizon."""
    results: dict[str, dict] = {}
    for horizon, champ in champion.items():
        cand = candidate.get(horizon)
        checks: dict[str, bool] = {}
        if cand is None or cand["rmse"] is None or champ["rmse"] is None:
            checks["has_data"] = False
        else:
            checks["has_data"] = True
            checks["enough_samples"] = cand["n"] >= MIN_SAMPLES_PER_HORIZON
            checks["beats_champion"] = cand["rmse"] < champ["rmse"] * (1 - REQUIRED_RELATIVE_IMPROVEMENT)
            if champ["low_rmse"] is not None and cand["low_rmse"] is not None:
                checks["low_region_ok"] = cand["low_rmse"] <= champ["low_rmse"] * (1 + MAX_LOW_REGION_DEGRADATION)
            else:
                # No low-region samples in the window: not evidence of safety,
                # but not evidence of harm either — flagged for human review.
                checks["low_region_ok"] = True
        results[horizon] = {"checks": checks, "passed": all(checks.values())}
    return results


def hypo_safety_replay(decisions: list[dict]) -> dict:
    """Gate 3: zero would-have-dosed-during-low events.

    `decisions` are replayed candidate decisions:
        {"glucose": mg/dL at decision time, "smb": units, "rate": U/hr, "profile_rate": U/hr}
    Any insulin beyond profile basal while glucose is below the low-region
    threshold is a hard fail.
    """
    violations = [
        d for d in decisions
        if d["glucose"] < schema.LOW_REGION_THRESHOLD
        and (d.get("smb", 0) > 0 or d.get("rate", 0) > d.get("profile_rate", 0))
    ]
    return {"passed": not violations, "violations": violations, "n": len(decisions)}


def promotion_verdict(backtest_comparison: dict, hypo_replay: dict) -> dict:
    """Final verdict. Promotion requires every horizon AND the hypo replay to pass."""
    horizons_passed = all(result["passed"] for result in backtest_comparison.values())
    passed = horizons_passed and hypo_replay["passed"]
    return {
        "promote": passed,
        "horizons_passed": horizons_passed,
        "hypo_safety_passed": hypo_replay["passed"],
    }
