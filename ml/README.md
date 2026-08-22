# trioml — offline training pipeline for the ML dosing engine

Companion to `docs/ML_DOSING_REPLACEMENT_PLAN.md`. This package consumes the raw
JSONL export produced in-app by `MLDataExporter` (Documents/ml_export/…jsonl) and
provides:

- `trioml.schema` — the versioned export/frame schema shared with the Swift side
- `trioml.dataset` — raw events → 5-minute training frames with IOB decomposition
  and future-glucose labels
- `trioml.insulin` — exponential insulin activity/IOB curves (oref-compatible)
- `trioml.baseline` — naive predictors every candidate model must beat
- `trioml.backtest` — frame-by-frame replay computing RMSE at 30/60/120-min
  horizons plus low-glucose-region metrics
- `trioml.gates` — the promotion gate suite: a candidate model may only be
  promoted if it beats the champion on the newest held-out data AND does not
  degrade in the low region AND passes the hypo-safety replay
  (zero would-have-dosed-during-low events). A failed gate means the champion
  keeps running.
- `trioml.features` — frames → model samples: 6-h history windows, insulin-plan
  conditioning channels, masked future-trajectory labels (gaps are masked,
  never interpolated into labels)
- `trioml.model` — the quantile dynamics model (plan §2.2): a small temporal
  conv net predicting p10/p50/p90 glucose trajectories over 4 h, conditioned
  on history + an insulin plan, trained with low-quantile-weighted pinball
  loss; quantile ordering holds by construction. Requires torch; everything
  else is stdlib-only so the gate suite runs anywhere
- `trioml.estimator` — CGM-lag-compensating Kalman StateEstimator prototype
- `trioml.oref` — oref's exported `predBGs` curves as the champion forecaster:
  scenario selection (cob while carbs are on board, else uam, else iob — never
  zt), aligned to frame anchors, returning None wherever oref didn't predict
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
# run the test suite (stdlib only; the torch model tests skip themselves
# when torch is absent)
python3 -m unittest discover -s ml/tests -v

# build frames from an export
python3 -c "
from trioml.dataset import load_events, build_frames
events = load_events('trio-training-export-….jsonl')
frames = build_frames(events)
print(len(frames), 'frames')
"

# train the dynamics model and run the promotion gate suite on held-out days
pip install torch
python3 ml/train_dynamics.py trio-training-export-….jsonl --outdir ml/output

# validate the StateEstimator against the same export (plan §7, item 12)
python3 ml/validate_estimator.py trio-training-export-….jsonl --outdir ml/output
```

`train_dynamics.py` holds out the newest days (`--test-days`, default 3),
scores the candidate against the naive baselines on identical (frame, horizon)
pairs, checks the low-quantile calibration gate, and writes the report plus a
checksummed model artifact to `--outdir` (gitignored — it derives from
personal health data). Exports whose determinations carry `predBGs` (the app
exporter now includes them) additionally gate the candidate against oref's own
forecasts, scored only on the pairs oref actually predicted; older exports
fall back to the baselines as the bar.

```bash
# convert a promote-verdict artifact to Core ML (refuses failed candidates)
pip install coremltools
python3 ml/export_coreml.py ml/output
```

This writes `DynamicsModel.mlpackage` (torch weights checksum stamped into its
metadata) plus `coreml_verification.json` — seeded synthetic input/output
pairs from the torch model. Linux cannot execute Core ML, so the Mac/app side
must replay those cases through the compiled model and demand agreement within
tolerance before trusting the artifact.

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
- Targets are the CGM readings at +30 and +60 minutes.
- Samples are dropped rather than interpolated when the CGM history or
  target window spans a gap, or when no recent determination exists; the
  skip counts are reported per reason in `metrics.json`.
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
question than the ML's +30/+60 min forecasts, so oref's MAE here is
expected to look worse than it is. Exporting the determination `predBGs`
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
it records +30/+60 min forecasts after each loop cycle for retrospective
comparison in Statistics → Forecasts, and has no influence on dosing.

## Known limitations

- Delivered basal outside temp segments is assumed to be 0 U/hr. That is
  correct for a zero-scheduled-basal profile but wrong otherwise; the export
  does not currently include the basal schedule.
- Boluses are not in the export; insulin features come from temp basals and
  the determination IOB only.
- `mae_below_120` (hypo-side accuracy) is only reported when the test window
  contains readings below 120 mg/dL.
