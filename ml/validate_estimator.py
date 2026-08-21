#!/usr/bin/env python3
"""Validate the StateEstimator against a real export (plan §7, item 12).

The estimator claims to compensate CGM lag: its estimate of glucose *now* at
time t should match the reading that is delivered ~lag minutes later better
than the raw reading at t does (a raw reading at t+lag reflects blood glucose
around t). This replays an export's CGM stream and scores exactly that,
overall and split by how fast glucose was moving — lag compensation only
matters when glucose moves, so the flat-glucose rows are expected to tie.

    python3 ml/validate_estimator.py /path/to/trio-training-export.jsonl
"""

from __future__ import annotations

import argparse
import json
import math
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from trioml import dataset, estimator

# A "reading at t + lag" is accepted this far from the exact lag offset.
MATCH_TOLERANCE_MINUTES = 1.5
WARMUP_READINGS = 12  # skip the first hour while the filter converges
TREND_SPLIT_MGDL_PER_5MIN = 5.0


def rmse(errors: list[float]) -> float | None:
    if not errors:
        return None
    return math.sqrt(sum(e * e for e in errors) / len(errors))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("export", help="trio-training-export JSONL path")
    parser.add_argument(
        "--lag", type=float, default=estimator.DEFAULT_LAG_MINUTES,
        help="lag the estimator assumes (its compensation parameter)",
    )
    parser.add_argument(
        "--reference-offset", type=float, default=estimator.DEFAULT_LAG_MINUTES,
        help="minutes ahead of t to take the reference reading — the sensor's "
             "presumed true lag, deliberately independent of --lag so sweeping "
             "the assumed lag keeps a fixed target",
    )
    parser.add_argument("--outdir", default="ml/output")
    args = parser.parse_args()

    events = dataset.load_events(args.export)
    readings: list[tuple[float, float]] = []
    for event in events:
        if event["type"] == "glucose" and not event.get("isManual"):
            readings.append((dataset._parse_iso(event["date"]), float(event["glucose"])))
    readings.sort()

    estimates = estimator.replay(readings, lag_minutes=args.lag)

    raw_errors: list[float] = []
    est_errors: list[float] = []
    moving_raw: list[float] = []
    moving_est: list[float] = []
    skipped_qc = 0
    unmatched = 0
    future_index = 0
    for i, ((t, raw), est) in enumerate(zip(readings, estimates)):
        if i < WARMUP_READINGS:
            continue
        if est.reading_suspect or est.stale:
            skipped_qc += 1
            continue
        # The reading delivered ~offset minutes later is the reference for
        # "blood glucose around t" — itself noisy and lagged, but it is the
        # plan's stated validation target and identically penalizes both
        # contestants.
        target_time = t + args.reference_offset
        while future_index < len(readings) and readings[future_index][0] < target_time - MATCH_TOLERANCE_MINUTES:
            future_index += 1
        if future_index >= len(readings) or readings[future_index][0] > target_time + MATCH_TOLERANCE_MINUTES:
            unmatched += 1
            continue
        reference = readings[future_index][1]
        raw_error = raw - reference
        est_error = est.glucose_now - reference
        raw_errors.append(raw_error)
        est_errors.append(est_error)
        if i > 0 and abs(raw - readings[i - 1][1]) >= TREND_SPLIT_MGDL_PER_5MIN:
            moving_raw.append(raw_error)
            moving_est.append(est_error)

    report = {
        "export": Path(args.export).name,
        "lag_minutes": args.lag,
        "reference_offset_minutes": args.reference_offset,
        "readings": len(readings),
        "scored": len(raw_errors),
        "skipped_qc": skipped_qc,
        "unmatched": unmatched,
        "rmse_raw_vs_future": rmse(raw_errors),
        "rmse_estimate_vs_future": rmse(est_errors),
        "moving": {
            "n": len(moving_raw),
            "rmse_raw": rmse(moving_raw),
            "rmse_estimate": rmse(moving_est),
        },
    }
    outdir = Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)
    (outdir / "estimator_report.json").write_text(json.dumps(report, indent=2))

    print(json.dumps(report, indent=2))
    if report["rmse_estimate_vs_future"] is not None and report["rmse_raw_vs_future"] is not None:
        improvement = 1 - report["rmse_estimate_vs_future"] / report["rmse_raw_vs_future"]
        print(f"\nestimate beats raw by {improvement:.1%} overall "
              f"({1 - report['moving']['rmse_estimate'] / report['moving']['rmse_raw']:.1%} while moving)"
              if report["moving"]["rmse_raw"] else "")


if __name__ == "__main__":
    main()
