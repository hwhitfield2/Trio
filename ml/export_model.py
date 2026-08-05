#!/usr/bin/env python3
"""Export BG-forecast models as a portable JSON tree ensemble for the app.

Usage:
    python3 ml/export_model.py <export.jsonl> [--outfile Trio/Resources/json/defaults/TrioMLForecaster.json]

Retrains on ALL samples with GradientBoostingRegressor (its trees are
plain decision trees, trivially portable — unlike HistGradientBoosting's
binned predictors) and writes one ensemble per horizon plus feature
metadata. A pure-Python reference evaluator then re-predicts every
training sample from the exported JSON and asserts exact agreement with
sklearn, so the JSON is proven faithful before it ever reaches Swift.

Also writes test fixtures (feature vectors + expected predictions) that
the app's unit tests replay against the Swift evaluator.

The exported model is shadow-mode only: the app uses it for display and
retrospective scoring, never for dosing.
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

from train import HORIZONS_MIN, build_samples, load_export

MODEL_VERSION = "1"


def tree_to_dict(tree):
    t = tree.tree_
    return {
        "childrenLeft": t.children_left.tolist(),
        "childrenRight": t.children_right.tolist(),
        "feature": t.feature.tolist(),
        "threshold": [round(x, 6) for x in t.threshold.tolist()],
        "value": [round(v[0][0], 6) for v in t.value.tolist()],
    }


def predict_from_json(model_json, x):
    """Reference implementation of the Swift evaluator, kept deliberately dumb."""
    total = model_json["baseline"]
    for tree in model_json["trees"]:
        node = 0
        while tree["childrenLeft"][node] != -1:
            if x[tree["feature"][node]] <= tree["threshold"][node]:
                node = tree["childrenLeft"][node]
            else:
                node = tree["childrenRight"][node]
        total += model_json["learningRate"] * tree["value"][node]
    return total


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export", help="Trio training export (.jsonl)")
    parser.add_argument("--outfile", default="Trio/Resources/json/defaults/TrioMLForecaster.json")
    parser.add_argument("--fixtures", default="TrioTests/JSONImporterData/MLForecasterFixtures.json")
    args = parser.parse_args()

    from sklearn.ensemble import GradientBoostingRegressor

    _, records = load_export(args.export)
    X, y, times, feature_names, _ = build_samples(records)
    if len(X) < 100:
        sys.exit(f"only {len(X)} usable samples — not enough to train")

    bundle = {
        "modelVersion": MODEL_VERSION,
        "trainedOnSamples": len(X),
        "featureNames": feature_names,
        "horizons": {},
    }
    fixtures = {"modelVersion": MODEL_VERSION, "cases": []}

    rng = np.random.RandomState(0)
    fixture_idx = rng.choice(len(X), size=min(20, len(X)), replace=False)

    for h in HORIZONS_MIN:
        model = GradientBoostingRegressor(
            n_estimators=150, max_depth=3, learning_rate=0.05, random_state=0
        )
        model.fit(X, y[h])

        model_json = {
            "learningRate": model.learning_rate,
            "baseline": round(float(model.init_.constant_[0][0]), 6),
            "trees": [tree_to_dict(est[0]) for est in model.estimators_],
        }

        # Prove the JSON reproduces sklearn before shipping it
        sk_pred = model.predict(X)
        json_pred = np.array([predict_from_json(model_json, x) for x in X])
        max_dev = float(np.max(np.abs(sk_pred - json_pred)))
        if max_dev > 0.01:
            sys.exit(f"JSON evaluator deviates from sklearn by {max_dev} at {h}min — aborting")
        print(f"{h}min: {len(model_json['trees'])} trees, max deviation vs sklearn {max_dev:.6f} mg/dL")

        bundle["horizons"][str(h)] = model_json
        for i in fixture_idx:
            fixtures["cases"].append({
                "horizon": h,
                "features": [round(float(v), 6) for v in X[i]],
                "expected": round(float(json_pred[i]), 4),
            })

    out = Path(args.outfile)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(bundle))
    Path(args.fixtures).write_text(json.dumps(fixtures, indent=2))
    print(f"wrote {out} ({out.stat().st_size // 1024} KB) and {args.fixtures}")


if __name__ == "__main__":
    main()
