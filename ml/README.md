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

## Known limitations

- Delivered basal outside temp segments is assumed to be 0 U/hr. That is
  correct for a zero-scheduled-basal profile but wrong otherwise; the export
  does not currently include the basal schedule.
- Boluses are not in the export; insulin features come from temp basals and
  the determination IOB only.
- `mae_below_120` (hypo-side accuracy) is only reported when the test window
  contains readings below 120 mg/dL.
