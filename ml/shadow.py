#!/usr/bin/env python3
"""Shadow-mode comparison: ML forecasts vs oref, on identical timestamps.

Usage:
    python3 ml/shadow.py <export.jsonl> [--outdir ml/output]

Replays the export walk-forward by day: for each day, models are trained
only on strictly earlier data, then score their +30/+60 min forecasts
against what the CGM actually did. On the same timestamps, oref's
`eventualBG` forecast and a persistence baseline are scored identically.

Caveat: the export carries only oref's eventualBG (where BG lands after all
insulin/carb activity), not its predBG curves, so oref is answering a
longer-horizon question than the ML models. Exporting the predBGs arrays
from determinations would make this comparison exact.

Shadow mode observes and reports. It changes nothing about dosing.
"""

import argparse
import bisect
import json
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from train import (
    HORIZONS_MIN,
    GlucoseSeries,
    TARGET_TOLERANCE_S,
    build_samples,
    load_export,
)

MIN_TRAIN_SAMPLES = 80
DISAGREEMENT_MGDL = 40


def utc_day(ts):
    return datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%Y-%m-%d")


def make_models():
    from sklearn.ensemble import HistGradientBoostingRegressor
    from sklearn.linear_model import Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler

    return {
        "ml_ridge": make_pipeline(StandardScaler(), Ridge(alpha=1.0)),
        "ml_gbdt": HistGradientBoostingRegressor(
            max_iter=200, max_depth=3, learning_rate=0.05, random_state=0
        ),
    }


def walk_forward_predictions(X, y, times):
    """Expanding-window daily walk-forward. Returns {horizon: {name: {i: pred}}}."""
    days = sorted({utc_day(t) for t in times})
    preds = {h: defaultdict(dict) for h in HORIZONS_MIN}
    scored_days, skipped_days = [], []
    for day in days:
        train_idx = [i for i, t in enumerate(times) if utc_day(t) < day]
        test_idx = [i for i, t in enumerate(times) if utc_day(t) == day]
        if len(train_idx) < MIN_TRAIN_SAMPLES:
            skipped_days.append(day)
            continue
        scored_days.append(day)
        for h in HORIZONS_MIN:
            for name, model in make_models().items():
                model.fit(X[train_idx], y[h][train_idx])
                for i, p in zip(test_idx, model.predict(X[test_idx])):
                    preds[h][name][i] = float(p)
    return preds, scored_days, skipped_days


def oref_eventual_at(determinations, t, tolerance_s=450):
    """eventualBG from the determination nearest to t, if fresh enough."""
    ts = [d["ts"] for d in determinations]
    i = bisect.bisect_right(ts, t) - 1
    if i >= 0 and t - ts[i] <= tolerance_s and "eventualBG" in determinations[i]:
        return float(determinations[i]["eventualBG"])
    return None


def situation_tags(t, bg, carbs_ts):
    tags = ["all"]
    tags.append("bg_low" if bg < 120 else "bg_in_range" if bg <= 180 else "bg_high")
    i = bisect.bisect_left(carbs_ts, t)
    post_meal = i > 0 and t - carbs_ts[i - 1] <= 3 * 3600
    tags.append("post_meal_3h" if post_meal else "no_recent_meal")
    return tags


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", help="Trio training export (.jsonl)")
    parser.add_argument("--outdir", default="ml/output")
    args = parser.parse_args()

    header, records = load_export(args.export)
    X, y, times, feature_names, skipped = build_samples(records)
    series = GlucoseSeries(records["glucose"])
    dets = [d for d in records["determination"] if "eventualBG" in d]
    carbs_ts = [c["ts"] for c in records["carbs"]]

    preds, scored_days, skipped_days = walk_forward_predictions(X, y, times)

    # Score every system on the identical joint sample set per horizon.
    errors = {h: defaultdict(lambda: defaultdict(list)) for h in HORIZONS_MIN}
    disagreements = []
    joint = {h: 0 for h in HORIZONS_MIN}
    for h in HORIZONS_MIN:
        for i, t in enumerate(times):
            if i not in preds[h]["ml_gbdt"]:
                continue
            actual = series.at(t + h * 60, TARGET_TOLERANCE_S)
            oref = oref_eventual_at(dets, t)
            if actual is None or oref is None:
                continue
            joint[h] += 1
            bg_now = X[i][0]
            forecasts = {
                "persistence": bg_now,
                "oref_eventualBG": oref,
                "ml_ridge": preds[h]["ml_ridge"][i],
                "ml_gbdt": preds[h]["ml_gbdt"][i],
            }
            for tag in situation_tags(t, bg_now, carbs_ts):
                for name, f in forecasts.items():
                    errors[h][tag][name].append(abs(f - actual))
            gap = forecasts["ml_gbdt"] - oref
            if h == 60 and abs(gap) >= DISAGREEMENT_MGDL:
                disagreements.append({
                    "at": datetime.fromtimestamp(t, tz=timezone.utc).isoformat(),
                    "bg": bg_now,
                    "ml_gbdt": round(forecasts["ml_gbdt"], 1),
                    "oref_eventualBG": oref,
                    "actual_60min": actual,
                    "closer": "ml" if abs(forecasts["ml_gbdt"] - actual) < abs(oref - actual) else "oref",
                })

    report = {
        "exported_at": header.get("exportedAt") if header else None,
        "scored_days": scored_days,
        "skipped_days_insufficient_history": skipped_days,
        "joint_samples": joint,
        "note": "oref_eventualBG is a longer-horizon forecast than the ML columns; "
                "export predBGs arrays for an exact comparison",
        "mae_by_situation": {},
        "disagreements_60min": disagreements,
    }
    for h in HORIZONS_MIN:
        report["mae_by_situation"][f"{h}min"] = {
            tag: {name: {"mae": round(float(np.mean(v)), 1), "n": len(v)}
                  for name, v in sorted(systems.items())}
            for tag, systems in sorted(errors[h].items())
        }

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "shadow_report.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
