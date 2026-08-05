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
