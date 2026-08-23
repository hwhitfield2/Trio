# trioml — offline training pipeline for the ML dosing engine

Companion to `docs/ML_DOSING_REPLACEMENT_PLAN.md`. This package consumes the raw
JSONL export produced in-app by `MLDataExporter` (Documents/ml_export/…jsonl) and
provides:

- `trioml.schema` — the versioned export/frame schema shared with the Swift side
- `trioml.dataset` — raw events → 5-minute training frames with IOB decomposition
  and future-glucose labels
- `trioml.insulin` — exponential insulin activity/IOB curves (oref-compatible)
- `trioml.baseline` — naive predictors every candidate model must beat
- `trioml.backtest` — frame-by-frame replay computing RMSE at every
  performance-check horizon (30/60/120/240/360 min — i.e. out to 6 h) plus
  low-glucose-region metrics
- `trioml.gates` — the promotion gate suite: a candidate model may only be
  promoted if it beats the champion on the newest held-out data AND does not
  degrade in the low region AND passes the hypo-safety replay
  (zero would-have-dosed-during-low events). A failed gate means the champion
  keeps running.
- `trioml.model` — quantile-regression sequence model skeleton (requires torch;
  everything else is stdlib-only so the gate suite runs anywhere)
- `trioml.estimator` — CGM-lag-compensating Kalman StateEstimator prototype
- `trioml.nightscout` — Nightscout → export-schema converter (deep history:
  the phone retains only 90 days; a long-running Nightscout site holds more)
- `trioml.merge` — deduplicating merge of overlapping sources (periodic app
  exports + Nightscout) into one training corpus

## Working with limited data

The pipeline is designed to start small and grow:

- StateEstimator validation needs only ~2-3 days of readings.
- Model training becomes meaningful around 3-4 weeks of frames; below
  `gates.MIN_SAMPLES_PER_HORIZON` the promotion gates fail closed and oref
  keeps dosing — insufficient data costs time, never safety.
- Archive every in-app export (CoreData purges at 90 days) and merge them with
  `merge.merge_events(app_export_events, nightscout_events)`; the merged corpus
  is the long-term training set.
- Simulator pretraining (Phase 2) is the other lever: pretrain on virtual-patient
  data, fine-tune on the personal corpus.

## Usage

```bash
# run the test suite (stdlib only)
python3 -m unittest discover -s ml/tests -v

# build frames from an export
python3 -c "
from trioml.dataset import load_events, build_frames
events = load_events('trio-training-export-….jsonl')
frames = build_frames(events)
print(len(frames), 'frames')
"
```

## Invariants

- No model doses. This pipeline only trains and evaluates; promotion produces a
  signed Core ML artifact that the app's fallback ladder and SafetyEnvelope
  still constrain at runtime.
- The schema version in the export header must match `trioml.schema.EXPORT_SCHEMA_VERSION`;
  a mismatch is a hard error, never a silent skip.
- Gates compare like-for-like: same weeks, same frames, candidate vs. champion.

---

# Quick-look scripts (train.py / shadow.py / export_model.py)

Standalone sklearn-based counterparts to `trioml`, kept for fast
iteration and for the in-app shadow forecaster. They read the same
training export JSONL.

Trains blood-glucose forecast models from a Trio training export (the JSONL
produced by the in-app exporter: a `header` record followed by `glucose`,
`determination`, `pump`, and `carbs` records).

> **Safety:** this is a research tool for studying predictability of the
> loop's data. Its models and outputs must not be used to dose insulin.

## Usage

```sh
pip install scikit-learn
python3 ml/train.py /path/to/trio-training-export.jsonl --outdir ml/output
```

Do **not** commit export files or the output directory — they contain
personal health data. Both are ignored via `ml/.gitignore`.

## What it does

- Builds one sample per CGM reading. Features use only information available
  at that moment: current BG, deltas over 5/15/30 min, IOB/COB/sensitivity
  from the most recent determination (≤30 min old), delivered temp-basal
  rate reconstructed from pump events, insulin delivered in the last hour,
  carbs entered in the last 1 h/3 h, and time of day.
- Targets are the CGM readings at +30 and +60 minutes and at the 2/4/6-hour
  performance-check horizons. Targets are tracked per horizon: a sample whose
  +6 h reading is missing still trains and scores the shorter horizons.
- Samples are dropped rather than interpolated when the CGM history spans a
  gap, when no recent determination exists, or when no target exists at any
  horizon; the skip counts are reported per reason in `metrics.json`.
- Chronological 80/20 train/test split (never random — adjacent CGM readings
  are heavily correlated).
- Trains Ridge regression and a gradient-boosted tree model, and reports
  MAE/RMSE against two baselines: persistence (BG stays where it is) and
  linear trend extrapolation. A model is only interesting if it beats
  persistence.

## Shadow mode

```sh
python3 ml/shadow.py /path/to/trio-training-export.jsonl --outdir ml/output
```

Replays the export walk-forward by day — each day is scored by models
trained only on strictly earlier days — and compares, on identical
timestamps: persistence, oref's `eventualBG` forecast, and the ML models.
`shadow_report.json` breaks MAE down by situation (BG band, post-meal vs
not) and logs every timestamp where ML and oref disagreed by ≥40 mg/dL
along with what actually happened.

Important caveat: the export contains only oref's `eventualBG` (where BG
lands after all insulin/carb activity), which answers a longer-horizon
question than the ML's short-horizon forecasts, so oref's MAE here is
expected to look worse than it is at 30/60 min (and more comparable at the
2/4/6 h checks). Exporting the determination `predBGs`
arrays would make the comparison exact. Shadow mode observes and reports
only — it changes nothing about dosing.

## Exporting the model into the app

```sh
python3 ml/export_model.py /path/to/trio-training-export.jsonl
```

Retrains on all usable samples with `GradientBoostingRegressor` (portable
plain trees), writes `Trio/Resources/json/defaults/TrioMLForecaster.json`,
and verifies in-process that a reference evaluator reproduces sklearn's
predictions exactly before writing anything. It also refreshes
`TrioTests/JSONImporterData/MLForecasterFixtures.json`, which the app's
`MLForecasterTests` replay against the Swift evaluator — so a mismatch
between Python and Swift fails the test suite, not the user.

In the app the model runs in **shadow mode only** (`MLForecastService`):
it records forecasts at every performance-check horizon (+30/+60 min and
+2/+4/+6 h) after each loop cycle for retrospective comparison in
Statistics → Forecasts, and has no influence on dosing.

## Known limitations

- Delivered basal outside temp segments is assumed to be 0 U/hr. That is
  correct for a zero-scheduled-basal profile but wrong otherwise; the export
  does not currently include the basal schedule.
- Boluses are not in the export; insulin features come from temp basals and
  the determination IOB only.
- `mae_below_120` (hypo-side accuracy) is only reported when the test window
  contains readings below 120 mg/dL.
