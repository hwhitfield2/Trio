#!/usr/bin/env python3
"""Train the quantile dynamics model on a Trio training export and gate it.

Phase 2 of docs/ML_DOSING_REPLACEMENT_PLAN.md: build 5-min frames from the
raw export, train the QuantileTCN (p10/p50/p90 trajectories conditioned on
history + delivered insulin), backtest it on held-out days against the naive
baselines, and run the promotion gate suite. The verdict, metrics, and the
checksummed model artifact land in --outdir (gitignored — it derives from
personal health data).

    pip install torch  # everything else is stdlib
    python3 ml/train_dynamics.py /path/to/trio-training-export.jsonl

This trains and evaluates only. Nothing here doses insulin; a model that
passes these gates still runs shadow-only in the app until every later-phase
gate and human review says otherwise.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from trioml import backtest, baseline, dataset, features, gates, schema
from trioml import model as model_module

MINUTES_PER_DAY = 24 * 60


def split_by_days(samples: list[dict], test_days: int) -> tuple[list[dict], list[dict]]:
    """Holds out the newest `test_days` distinct UTC days for the gate backtest.

    Training samples whose label horizon reaches into the held-out days are
    dropped: a sample trained on test-region glucose is leakage, not evidence.
    """
    days = sorted({int(s["t"] // MINUTES_PER_DAY) for s in samples})
    if len(days) <= test_days:
        raise SystemExit(
            f"only {len(days)} days of samples; need more than --test-days {test_days}"
        )
    test_day_set = set(days[-test_days:])
    test_start = min(test_day_set) * MINUTES_PER_DAY
    train = [s for s in samples if s["t"] < test_start - schema.HORIZON_MINUTES]
    test = [s for s in samples if int(s["t"] // MINUTES_PER_DAY) in test_day_set]
    return train, test


def evaluate_heldout(forecaster, test_samples: list[dict]) -> dict:
    """Scores candidate + baselines on identical (sample, horizon) pairs."""
    candidate_records: list[dict] = []
    persistence_records: list[dict] = []
    trend_records: list[dict] = []
    calibration_samples: list[dict] = []
    coverage: dict[str, dict] = {
        str(h): {"p10_miss": 0, "p90_miss": 0, "n": 0} for h in schema.LABEL_HORIZONS_MINUTES
    }

    for sample in test_samples:
        prediction = forecaster.predict(sample)
        history_glucose = [
            features.denormalize_glucose(step[0]) for step in sample["history"]
        ]
        for horizon in schema.LABEL_HORIZONS_MINUTES:
            label = sample["labels"].get(str(horizon))
            if label is None:
                continue
            actual = float(label)
            step = features.horizon_step(horizon)
            p10 = prediction["p10"][step]
            p50 = prediction["p50"][step]
            p90 = prediction["p90"][step]

            candidate_records.append({"horizon": horizon, "predicted": p50, "actual": actual})
            persistence_records.append({
                "horizon": horizon,
                "predicted": baseline.last_value(history_glucose, horizon),
                "actual": actual,
            })
            trend_records.append({
                "horizon": horizon,
                "predicted": baseline.linear_trend(history_glucose, horizon),
                "actual": actual,
            })
            calibration_samples.append({"p10": p10, "actual": actual})
            stats = coverage[str(horizon)]
            stats["n"] += 1
            stats["p10_miss"] += 1 if actual < p10 else 0
            stats["p90_miss"] += 1 if actual > p90 else 0

    return {
        "candidate": backtest.metrics_from_predictions(candidate_records),
        "persistence": backtest.metrics_from_predictions(persistence_records),
        "linear_trend": backtest.metrics_from_predictions(trend_records),
        "calibration_samples": calibration_samples,
        "coverage": {
            horizon: {
                "n": stats["n"],
                "p10_miss_rate": stats["p10_miss"] / stats["n"] if stats["n"] else None,
                "p90_miss_rate": stats["p90_miss"] / stats["n"] if stats["n"] else None,
            }
            for horizon, stats in coverage.items()
        },
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("export", help="trio-training-export JSONL path")
    parser.add_argument("--outdir", default="ml/output", help="report + artifact directory")
    parser.add_argument("--test-days", type=int, default=3, help="held-out days for the gate backtest")
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--seed", type=int, default=7)
    args = parser.parse_args()

    if not model_module.HAS_TORCH:
        raise SystemExit("torch is required to train the dynamics model: pip install torch")

    events = dataset.load_events(args.export)
    frames = dataset.build_frames(events)
    samples = features.build_samples(frames)
    print(f"{len(events)} events → {len(frames)} frames → {len(samples)} samples")

    train_samples, test_samples = split_by_days(samples, args.test_days)
    print(f"train {len(train_samples)} / held-out {len(test_samples)} samples ({args.test_days} newest days)")

    config = model_module.TrainConfig(epochs=args.epochs, seed=args.seed)
    trained, train_report = model_module.train_model(train_samples, config)
    print(
        f"trained {train_report['parameters']} params, best epoch "
        f"{train_report['best_epoch']}/{train_report['epochs_run']}, "
        f"val pinball {train_report['best_val_pinball']:.4f}"
    )

    forecaster = model_module.QuantileForecaster(trained)
    evaluation = evaluate_heldout(forecaster, test_samples)

    comparisons = {
        name: gates.compare_backtests(evaluation["candidate"], evaluation[name])
        for name in ("persistence", "linear_trend")
    }
    combined_comparison = {
        f"{name}:{horizon}": result
        for name, comparison in comparisons.items()
        for horizon, result in comparison.items()
    }
    calibration = gates.low_quantile_calibration(evaluation["calibration_samples"])
    # Forecast-only candidate: there are no dosing decisions to replay yet.
    # The hypo-safety replay becomes a real gate when the controller exists.
    hypo_replay = gates.hypo_safety_replay([])
    verdict = gates.promotion_verdict(combined_comparison, hypo_replay, calibration)

    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    meta = model_module.save_model(trained, train_report, outdir)
    report = {
        "export": Path(args.export).name,
        "frames": len(frames),
        "samples": {"train": len(train_samples), "heldout": len(test_samples)},
        "training": train_report,
        "metrics": {k: evaluation[k] for k in ("candidate", "persistence", "linear_trend")},
        "coverage": evaluation["coverage"],
        "gates": {
            "comparisons": comparisons,
            "calibration": calibration,
            "hypo_replay": {"passed": hypo_replay["passed"], "n": hypo_replay["n"]},
        },
        "verdict": verdict,
        "weights_sha256": meta["weights_sha256"],
    }
    report_path = outdir / "dynamics_report.json"
    report_path.write_text(json.dumps(report, indent=2))

    print(f"\n{'horizon':>8} {'candidate':>10} {'persist':>10} {'trend':>10} {'n':>6}   (RMSE mg/dL)")
    for horizon in schema.LABEL_HORIZONS_MINUTES:
        row = [evaluation[k][str(horizon)] for k in ("candidate", "persistence", "linear_trend")]
        print(
            f"{horizon:>8} {row[0]['rmse']:>10.1f} {row[1]['rmse']:>10.1f} "
            f"{row[2]['rmse']:>10.1f} {row[0]['n']:>6}"
        )
    print(f"\np10 miss rate {calibration['miss_rate']:.3f} over {calibration['n']} "
          f"(gate ≤ {gates.MAX_LOW_QUANTILE_MISS_RATE})" if calibration["miss_rate"] is not None
          else f"\ncalibration: insufficient data (n={calibration['n']})")
    print(f"promotion verdict: {verdict}")
    print(f"report: {report_path}")


if __name__ == "__main__":
    main()
