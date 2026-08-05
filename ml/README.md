# BG-forecast training pipeline

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
