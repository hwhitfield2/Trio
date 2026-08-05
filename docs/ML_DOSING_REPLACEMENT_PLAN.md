# Plan: Replacing oref with a Learned, Continuously-Adapting Dosing Controller

**Status:** Draft for review with care team
**Scope:** Personal-use build of Trio. Not for distribution.
**Objective:** Replace the oref (OpenAPS) decision algorithm with a machine-learning
controller that ingests glucose, carbs, and insulin-delivery history and chooses
insulin delivery (temp basal + micro-bolus) to minimize time outside
**target ± 15 mg/dL**, and that keeps improving as new personal data accumulates.

---

## 0. Design principles (non-negotiable)

These are what make an "ever-evolving" model survivable in a system that doses insulin.

1. **The policy is learned; the envelope is not.** The ML controller decides *how much*
   insulin to deliver. A deterministic, unit-tested Swift safety envelope decides *the
   maximum it is allowed to deliver* and *when it must deliver zero*. The envelope is
   versioned, hand-written, and never trained. Every model update in the future changes
   only the policy, never the envelope.
2. **Asymmetric objective.** Going low is weighted far more heavily than going high at
   every layer: the training loss, the controller cost function, and the envelope.
   Rescue meds treat lows after the fact; the controller's job is to make them rare.
3. **oref stays in the binary as the fallback, permanently.** Replacement means the ML
   path is primary, not that the proven algorithm is deleted. Any anomaly — stale CGM,
   missing model, out-of-distribution inputs, watchdog trip — degrades to oref (or to
   zero-temp) automatically, and a single settings toggle reverts entirely.
4. **No unvalidated model ever doses.** Retraining is continuous; *promotion* is gated.
   A new model version doses only after passing an automated backtest + safety
   regression suite against your own recent data and simulator stress scenarios.
5. **Dose against uncertainty, not the point estimate.** The model predicts a
   distribution of future glucose. Insulin is chosen so the *pessimistic-low* bound
   (e.g. 10th percentile) stays above the hypo threshold, while the median is steered
   toward target.

### Honest framing of the ±15 goal

CGM error alone is ~±9–10% MARD and subcutaneous insulin acts with a 15–30 min onset
and a multi-hour tail. No controller — learned or otherwise — can *guarantee* ±15 mg/dL
at all times, especially across unannounced meals. The goal is expressed as the
optimization objective: **maximize time-in-tight-range (target ± 15) subject to a hard
hypoglycemia constraint**. Realistic success looks like steadily rising tight-range
percentage across model generations, with lows never increasing. That metric is the
scoreboard for every model promotion.

---

## 1. Current architecture (what gets replaced, what stays)

Trio runs oref as JavaScript in JavaScriptCore. The loop cycle:

```
CGM reading → APSManager.loop() (APSManager.swift:232)
  → OpenAPS.determineBasal() (OpenAPS.swift:380)
      - assembles: glucose (GlucoseStored), carbs (CarbEntryStored),
        pump history (PumpEventStored), profile.json, autosens, TDD, reservoir
      - JS: meal() → iob() → determine_basal() (trio-oref/lib/determine-basal/determine-basal.js)
  → Determination {rate, duration, smb units, predBGs, reason}
  → CoreData (OrefDetermination + Forecast) → charts / Nightscout / watch
  → APSManager.enactDetermination() (APSManager.swift:706) → pump
```

**Replaced:** the JS `determine_basal` decision logic (and eventually meal/autosens as
the learned model subsumes them).

**Kept unchanged:** data assembly, the `Determination` output shape (so CoreData,
charts, Nightscout, Live Activity, and the watch app keep working), and enactment.

**Reimplemented in Swift (currently lives in JS and must not be lost):** max IOB
clamping, `maxSafeBasal`, SMB caps and interval, low-glucose threshold logic,
CGM-quality bailouts. Sources: `determine-basal.js` lines ~420–1620 and
`basal-set-temp.js`.

---

## 2. Target architecture

```
                       ┌────────────────────────────────────────────┐
                       │                DosingEngine                │
 5-min feature frame   │                                            │
 (glucose, IOB decomp, │  ┌──────────────┐    ┌──────────────────┐  │
  COB, time-of-day,    │  │  Dynamics    │    │   Controller     │  │
  recent doses, ...)──►│  │  Model       │───►│   (MPC search    │  │
                       │  │ (Core ML,    │    │   over candidate │  │
                       │  │  quantile    │    │   insulin plans) │  │
                       │  │  forecasts)  │    └────────┬─────────┘  │
                       │  └──────────────┘             │            │
                       │                     proposed rate + SMB    │
                       │                               ▼            │
                       │                    ┌──────────────────┐    │
                       │                    │  SafetyEnvelope  │    │
                       │                    │  (deterministic, │    │
                       │                    │   hand-written)  │    │
                       │                    └────────┬─────────┘    │
                       └─────────────────────────────┼──────────────┘
                                                     ▼
                                          Determination → pump
                        anomaly / low confidence / stale data
                                    └──► fallback: oref → zero-temp
```

### 2.1 Dynamics model (the learned part)

* **Task:** given the last 6 h of state and a *candidate* insulin plan for the next
  interval, predict the glucose trajectory for the next 4 h as quantiles
  (p10 / p50 / p90) at 5-min steps.
* **Features per 5-min frame:** glucose + deltas (15/30/60 min), IOB decomposed into
  future activity buckets, COB with absorption-rate estimate, insulin delivered per
  frame (basal & bolus separately), time-of-day encoding, day-of-week, active
  override/temp-target, recent TDD stats. This is essentially the tuple Trio already
  assembles each cycle (`AlgorithmGlucose`, `PumpEventDTO`, `TrioCustomOrefVariables`).
* **Architecture:** small sequence model — temporal convolutional network or GRU/LSTM,
  ~10⁵–10⁶ parameters, quantile-regression heads (pinball loss, extra weight on the
  low quantile). Trained in PyTorch, exported to Core ML. Runs in <50 ms on iPhone.
* **Also predicts:** a meal/absorption disturbance signal (learned successor to UAM),
  so unannounced carbs show up as a rising disturbance term the controller reacts to.

### 2.2 Controller (MPC — the deciding part)

Every loop cycle:

1. Enumerate candidate insulin plans: temp-basal rates from 0 to envelope max
   (in pump-supported increments) × SMB sizes from 0 to envelope max.
2. Roll each candidate through the dynamics model.
3. Score with an asymmetric cost over the 4-h horizon:
   * hard reject any plan whose **p10** trajectory crosses the hypo threshold;
   * heavy quadratic penalty below `target − 15` (on p50);
   * moderate penalty above `target + 15`, growing with excursion size and duration;
   * small penalty on insulin aggressiveness / dose-to-dose variability (prevents
     oscillation and rage-bolus behavior).
4. Choose the minimum-cost plan; pass it to the SafetyEnvelope.

This is the same *shape* as oref (which is MPC over a fixed physiological model) — the
replacement is the personalized learned model and a search over actions rather than a
single closed-form insulinReq. It is auditable: every decision logs the candidate set,
predicted trajectories, and cost breakdown into the `reason` field, so any dose can be
explained after the fact.

### 2.3 SafetyEnvelope (deterministic Swift)

Reimplements, as pure functions with exhaustive unit tests:

* `maxIOB` clamp (reject any plan pushing IOB past max)
* `maxSafeBasal = min(max_basal, max_daily_multiplier × max_daily_basal, current_multiplier × current_basal)`
* SMB cap (`maxSMBBasalMinutes` equivalent) + minimum SMB interval + `maxBolus`
* **Low-glucose suspend:** current or p10-predicted glucose below threshold ⇒ zero-temp,
  no SMB, regardless of what the model wants
* CGM quality gates: stale (>12 min), calibrating, flat-lined, implausible jumps ⇒ no
  ML dosing (fallback path)
* Rate-of-change guard: consecutive-cycle dose escalation limiter
* Pump-state guards (reuse existing `verifyStatus()`, suspension, manual-temp checks)

The envelope's thresholds come from the same user settings oref uses today
(`Preferences`, `PumpSettings`) — no new knobs to misconfigure.

### 2.4 Fallback ladder

```
ML healthy ──► ML controller doses
model missing / OOD input / confidence too wide / watchdog ──► oref doses
oref also unavailable (JS error, no profile) ──► cancel temp, profile basal, alert
CGM invalid ──► existing stale-data behavior (no dosing decisions)
```

"Confidence too wide" = p90 − p10 spread beyond a set band, or live prediction error
(last hour's predictions vs. actual) beyond a set RMSE — both checked every cycle.

---

## 3. Phased build

### Phase 1 — Data foundation (1–2 weeks of work)

* **Exporter:** new `MLDataExporter` service reading `GlucoseStored`,
  `CarbEntryStored`, `PumpEventStored`, `TDDStored`, `OverrideStored`,
  `OrefDetermination` + `Forecast` from CoreData; emits 5-min-aligned frames as
  CSV/JSONL via share sheet / Files app. Nightscout is the secondary source for
  history predating the current phone.
* **Shared feature schema:** one spec (versioned JSON schema) used by both the Python
  training code and the Swift inference code, with golden-file tests on both sides so
  train/serve skew is impossible.
* **Deliverable gate:** ≥ 60–90 days of clean personal data; audit for gaps, sensor
  swaps, site changes.

### Phase 2 — Offline model (2–4 weeks, iterative)

* Python training repo (can live under `ml/` here): dataset builder, model, training
  loop, and a **backtest harness** that replays history frame-by-frame.
* **Baseline to beat:** oref's own stored `predBGs` forecasts (already persisted per
  cycle in `Forecast`/`ForecastValue`). Gate: lower RMSE than oref at 30/60/120 min on
  held-out weeks, *and* no degradation in the low-glucose region specifically.
* Simulator stress-testing: run the controller against a virtual-patient simulator
  (e.g. a simglucose/UVA-Padova-style cohort) for meal, exercise, compression-low,
  sensor-dropout, and site-failure scenarios. The controller must never produce a
  simulated severe low that zero-temping would have avoided.

### Phase 3 — Swift integration, shadow mode (2–3 weeks + ≥ 4–6 weeks of runtime)

* New `DosingAlgorithm` protocol; `OrefAlgorithm` (existing path) and `MLAlgorithm`
  (Core ML dynamics model + MPC + SafetyEnvelope) both conform, both emit
  `Determination`.
* Settings toggle: **oref / ML-shadow / ML-active** (default oref).
* In **shadow mode**, every cycle runs both; oref doses; both determinations are
  persisted and uploaded to Nightscout for side-by-side review with your care team.
* **Promotion gates out of shadow:** over ≥ 4 weeks —
  * zero cycles where ML would have dosed insulin during an actual hypo (< threshold);
  * ML's live 30/60-min prediction RMSE beats oref's;
  * dose divergence review with care team (every large disagreement explained).

### Phase 4 — Staged activation (weeks to months, care-team-paced)

* **Stage A:** ML controls temp basals only; SMBs remain oref's; conservative maxIOB.
* **Stage B:** ML issues SMBs, capped at 50% of envelope max.
* **Stage C:** full authority within the envelope.
* Each stage begins with a care-team review of shadow/previous-stage data, runs a
  minimum of 2 weeks, and has the one-tap revert to oref. Advancement criteria:
  tight-range % non-inferior to oref, time-below-range not increased, no
  envelope-clamp events indicating the model *wanted* to overdose.

### Phase 5 — Continuous evolution (steady state)

Two adaptation loops at very different speeds:

* **Fast loop (on-device, bounded, daily):** a single sensitivity scalar — a learned
  successor to autosens — updated from the last 24–48 h of prediction error, hard-
  clamped to [0.7, 1.3]. This gives day-to-day adjustment (hormones, illness, site
  aging) without touching model weights. Safe because it is one bounded number.
* **Slow loop (off-device, gated, weekly/monthly):** phone exports new data → training
  pipeline (Mac or private CI) retrains → automated gate suite runs (backtest vs.
  current champion on the newest weeks, hypo-safety regression, simulator suite) →
  only a passing model is signed and promoted. The app loads versioned `.mlmodelc`
  files from Documents with checksum verification; every model version is kept for
  instant rollback; the app pins the champion version and displays it on the settings
  screen. A failed gate means the old model simply keeps running — evolution can
  stall, but it can never regress silently.

---

## 4. Testing matrix

| Layer | Test |
|---|---|
| SafetyEnvelope | Exhaustive unit tests incl. property-based tests (random model outputs can never produce dose > envelope); direct port of the oref JS safety cases as fixtures |
| Feature pipeline | Golden-file parity tests Python ↔ Swift |
| Dynamics model | Backtest RMSE gates vs. oref predBGs; low-region calibration check (predicted p10 must be conservative) |
| Controller | Simulator scenario suite (meals, exercise, missed meal announcements, sensor noise/dropout, occlusions); replay of your worst historical days |
| Integration | Shadow-mode divergence logging; watchdog/fallback fault-injection tests (kill model mid-cycle, corrupt input, stale CGM) |
| Rollback | One-tap revert to oref verified on-device before every stage advance |

---

## 5. Personal-safety operating rules (with care team)

* Rescue meds staged and in-date; support team knows which stage the system is in and
  the revert procedure (Settings → Algorithm → oref).
* Stage advances only after joint review of the data — never solo, never mid-week.
* Alarm floor: keep CGM urgent-low alarms independent of this system at all times.
* Any severe low or two consecutive nights below target band ⇒ automatic drop back one
  stage pending review.
* Keep Nightscout uploading both suggested and enacted determinations so the team has
  remote visibility.

---

## 6. Immediate next steps in this repo

1. `MLDataExporter` service + export UI entry point (Phase 1).
2. `SafetyEnvelope` Swift module with the oref JS safety cases ported as unit-test
   fixtures — it is needed by every later phase and can be built and fully tested now.
3. `DosingAlgorithm` protocol refactor wrapping the existing oref path unchanged.
4. `ml/` training scaffold: feature schema, dataset builder, backtest harness reading
   the exporter's output.
