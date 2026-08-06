#!/usr/bin/env python3
"""Train BG-forecast models from a Trio training export (JSONL).

Usage:
    python3 ml/train.py <export.jsonl> [--outdir ml/output]

The export is the JSONL produced by Trio's training exporter: a `header`
record followed by `glucose`, `determination`, `pump`, and `carbs` records.

The pipeline builds one sample per CGM reading (features use only data
available at that time), predicts BG at +30 and +60 minutes, and compares
Ridge and gradient-boosting models against persistence and linear-trend
baselines on a chronological train/test split.

This is a research tool. Its output must not be used to dose insulin.
"""

import argparse
import bisect
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

HORIZONS_MIN = (30, 60)

# A sample is dropped rather than built from stale or interpolated-over-gap
# data: CGM lookbacks tolerate small jitter, IOB/COB carry forward briefly.
CGM_TOLERANCE_S = 6 * 60
TARGET_TOLERANCE_S = 10 * 60
DETERMINATION_MAX_AGE_S = 30 * 60


def parse_ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def load_export(path):
    records = {"glucose": [], "determination": [], "pump": [], "carbs": []}
    header = None
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rec = json.loads(line)
            kind = rec.get("type")
            if kind == "header":
                header = rec
            elif kind in records:
                rec["ts"] = parse_ts(rec["date"])
                records[kind].append(rec)
    # Drop physiologically invalid CGM readings (below the ~39 mg/dL reporting
    # floor of a working sensor). These appear as a dying-sensor plunge right
    # before session gaps and would poison training targets.
    records["glucose"] = [r for r in records["glucose"] if r["glucose"] >= 39]
    for kind in records:
        records[kind].sort(key=lambda r: r["ts"])
    return header, records


class GlucoseSeries:
    def __init__(self, readings):
        self.ts = [r["ts"] for r in readings]
        self.bg = [float(r["glucose"]) for r in readings]

    def at(self, t, tolerance_s):
        """Nearest reading within tolerance, else None."""
        i = bisect.bisect_left(self.ts, t)
        best = None
        for j in (i - 1, i):
            if 0 <= j < len(self.ts):
                d = abs(self.ts[j] - t)
                if d <= tolerance_s and (best is None or d < best[0]):
                    best = (d, self.bg[j])
        return None if best is None else best[1]


class BasalSchedule:
    """Reconstructs the delivered temp-basal rate from pump events.

    Suspend forces 0 U/hr until resume; a temp basal applies for its stated
    duration. Outside any temp and any suspend the delivered rate is unknown
    (scheduled basal is not in the export), treated as 0 — accurate for this
    zero-scheduled-basal profile, revisit if profiles are exported later.
    """

    def __init__(self, pump_events):
        self.segments = []  # (start, end, rate)
        suspend_start = None
        for ev in pump_events:
            kind = ev["eventType"]
            if kind == "TempBasal":
                dur = ev.get("tempBasalDurationMinutes") or 0
                rate = ev.get("tempBasalRate") or 0.0
                self.segments.append((ev["ts"], ev["ts"] + dur * 60, float(rate)))
            elif kind == "PumpSuspend":
                suspend_start = ev["ts"]
            elif kind == "PumpResume" and suspend_start is not None:
                self.segments.append((suspend_start, ev["ts"], 0.0))
                suspend_start = None
        self.segments.sort()

    def rate_at(self, t):
        rate = 0.0
        for start, end, r in self.segments:
            if start <= t < end:
                rate = r  # later-starting segments override earlier ones
            elif start > t:
                break
        return rate

    def delivered_units(self, t_from, t_to, step_s=300):
        total = 0.0
        t = t_from
        while t < t_to:
            span = min(step_s, t_to - t)
            total += self.rate_at(t) * span / 3600.0
            t += span
        return total


def latest_determination(determinations, t, max_age_s):
    ts = [d["ts"] for d in determinations]
    i = bisect.bisect_right(ts, t) - 1
    if i >= 0 and t - determinations[i]["ts"] <= max_age_s:
        return determinations[i]
    return None


def build_samples(records):
    glucose = records["glucose"]
    series = GlucoseSeries(glucose)
    basal = BasalSchedule(records["pump"])
    dets = [d for d in records["determination"] if "iob" in d]
    carbs = records["carbs"]
    carb_ts = [c["ts"] for c in carbs]

    rows, targets, times = [], {h: [] for h in HORIZONS_MIN}, []
    skipped = {"cgm_history_gap": 0, "no_recent_determination": 0, "cgm_target_gap": 0}
    for r in glucose:
        t, bg = r["ts"], float(r["glucose"])

        lookbacks = {m: series.at(t - m * 60, CGM_TOLERANCE_S) for m in (5, 15, 30)}
        det = latest_determination(dets, t, DETERMINATION_MAX_AGE_S)
        futures = {h: series.at(t + h * 60, TARGET_TOLERANCE_S) for h in HORIZONS_MIN}
        if None in lookbacks.values():
            skipped["cgm_history_gap"] += 1
            continue
        if det is None:
            skipped["no_recent_determination"] += 1
            continue
        if None in futures.values():
            skipped["cgm_target_gap"] += 1
            continue

        i = bisect.bisect_left(carb_ts, t)
        recent_carbs_60 = sum(c["carbs"] for c in carbs[max(0, i - 8):i] if t - c["ts"] <= 3600)
        recent_carbs_180 = sum(c["carbs"] for c in carbs[max(0, i - 8):i] if t - c["ts"] <= 10800)

        hour = datetime.fromtimestamp(t, tz=timezone.utc).hour + \
            datetime.fromtimestamp(t, tz=timezone.utc).minute / 60.0
        rows.append([
            bg,
            bg - lookbacks[5],
            bg - lookbacks[15],
            bg - lookbacks[30],
            float(det["iob"]),
            float(det.get("cob", 0)),
            float(det.get("sensitivityRatio", 1.0)),
            basal.rate_at(t),
            basal.delivered_units(t - 3600, t),
            recent_carbs_60,
            recent_carbs_180,
            np.sin(2 * np.pi * hour / 24),
            np.cos(2 * np.pi * hour / 24),
        ])
        for h in HORIZONS_MIN:
            targets[h].append(futures[h])
        times.append(t)

    feature_names = [
        "bg", "delta_5m", "delta_15m", "delta_30m", "iob", "cob",
        "sensitivity_ratio", "basal_rate", "insulin_last_1h",
        "carbs_last_1h", "carbs_last_3h", "tod_sin", "tod_cos",
    ]
    X = np.array(rows)
    y = {h: np.array(targets[h]) for h in HORIZONS_MIN}
    return X, y, np.array(times), feature_names, skipped


def evaluate(y_true, y_pred):
    err = y_pred - y_true
    return {
        "mae": float(np.mean(np.abs(err))),
        "rmse": float(np.sqrt(np.mean(err ** 2))),
        "mae_below_120": float(np.mean(np.abs(err[y_true < 120]))) if (y_true < 120).any() else None,
        "n": int(len(y_true)),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", help="Trio training export (.jsonl)")
    parser.add_argument("--outdir", default="ml/output")
    parser.add_argument("--test-fraction", type=float, default=0.2)
    args = parser.parse_args()

    from sklearn.ensemble import HistGradientBoostingRegressor
    from sklearn.linear_model import Ridge
    from sklearn.pipeline import make_pipeline
    from sklearn.preprocessing import StandardScaler
    import joblib

    header, records = load_export(args.export)
    X, y, times, feature_names, skipped = build_samples(records)
    if len(X) < 100:
        sys.exit(f"only {len(X)} usable samples — not enough to train")

    split = int(len(X) * (1 - args.test_fraction))
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    results = {
        "exported_at": header.get("exportedAt") if header else None,
        "samples": len(X),
        "skipped": skipped,
        "train_samples": split,
        "test_samples": len(X) - split,
        "test_starts": datetime.fromtimestamp(times[split], tz=timezone.utc).isoformat(),
        "feature_names": feature_names,
        "horizons": {},
    }

    for h in HORIZONS_MIN:
        X_train, X_test = X[:split], X[split:]
        y_train, y_test = y[h][:split], y[h][split:]

        persistence = X_test[:, 0]
        trend = X_test[:, 0] + X_test[:, 3] * (h / 30.0)  # extrapolate delta_30m

        models = {
            "ridge": make_pipeline(StandardScaler(), Ridge(alpha=1.0)),
            "gbdt": HistGradientBoostingRegressor(
                max_iter=200, max_depth=3, learning_rate=0.05, random_state=0
            ),
        }
        horizon_report = {
            "baseline_persistence": evaluate(y_test, persistence),
            "baseline_trend": evaluate(y_test, trend),
        }
        for name, model in models.items():
            model.fit(X_train, y_train)
            horizon_report[name] = evaluate(y_test, model.predict(X_test))
            joblib.dump(model, outdir / f"{name}_{h}min.joblib")
        results["horizons"][f"{h}min"] = horizon_report

    (outdir / "metrics.json").write_text(json.dumps(results, indent=2))
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
