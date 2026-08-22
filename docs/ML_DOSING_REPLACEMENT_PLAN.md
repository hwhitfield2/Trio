# Plan: ML Closed-Loop Dosing Engine for Trio

**Status:** Draft v2 for review with care team
**Scope:** Personal-use build of Trio. Not for distribution.

**Objective:** The ML engine *is* the closed loop. It ingests glucose, carbs, and
insulin-delivery history; chooses insulin delivery (temp basal + micro-bolus) to
minimize time outside **target ± 15 mg/dL**; **runs strictly on CGM event delivery —
one cycle per new value, no re-cycle without one** (the sensor's ~5-min delivery
interval sets the cadence), compensating for CGM latency; **evolves hourly**; every
component is **individually toggleable**; every
decision carries a complete **who/what/where/when/why/how audit record**; and
**hard caps** on IOB, basal rate, SMB size, and insulin-per-hour/day are enforced by a
layer that no toggle, model update, or adaptation can bypass.

---

## 0. Design principles (non-negotiable)

1. **The policy is learned; the caps are not.** The ML controller decides *how much*.
   A deterministic, unit-tested Swift `SafetyEnvelope` — hand-written, versioned, never
   trained, and **not toggleable** — decides the maximum it may deliver and when it
   must deliver zero. Everything above the envelope can evolve hourly; the envelope
   changes only by explicit code change.
2. **Asymmetric objective.** Lows are weighted far more heavily than highs in the
   training loss, the controller cost, and the envelope.
3. **oref stays in the binary as the automatic fallback, permanently.** Replacement
   means the ML path is primary. Any anomaly degrades to oref, then to zero-temp +
   profile basal + alert. One-tap full revert in settings.
4. **Evolution is tiered by blast radius.** What changes hourly is *bounded parameters*
   (clamped scalars, residual corrections). What changes model *weights* passes an
   automated gate suite first, however frequently that pipeline runs. An unvalidated
   set of weights never doses.
5. **Dose against uncertainty.** The model predicts glucose quantiles (p10/p50/p90);
   insulin is chosen so the pessimistic-low bound stays above the hypo threshold while
   the median steers to target.
6. **Every decision is reconstructible.** If a dose can't be explained from its stored
   audit record alone — without the app, without the model — the audit layer is
   incomplete and the decision path doesn't ship.

### Honest framing of the ±15 goal

CGM MARD is ~9–10%, interstitial readings lag blood glucose, and subcutaneous insulin
has 15–30 min onset with a multi-hour tail. No controller can *guarantee* ±15 at all
times, especially across unannounced meals. The goal is the optimization objective:
**maximize time in target ± 15, subject to a hard hypoglycemia constraint.** The
scoreboard for every model generation: tight-range % must rise, time-below-range must
never rise.

---

## 1. What gets replaced, what stays

Trio today runs oref as JavaScript in JavaScriptCore
(`OpenAPS.determineBasal`, `Trio/Sources/APS/OpenAPS/OpenAPS.swift:380` →
`trio-oref/lib/determine-basal/determine-basal.js`).

* **Replaced:** the oref decision logic (determine-basal, and progressively
  meal-absorption and autosens as the learned model subsumes them).
* **Kept:** data assembly from CoreData, the `Determination` output shape (CoreData
  persistence, charts, Nightscout, Live Activity, and watch all keep working), and
  pump enactment (`APSManager.enactDetermination`, `APSManager.swift:706`).
* **Reimplemented in Swift:** the safety math that currently lives in the JS
  (max IOB, `maxSafeBasal`, SMB caps/interval, low-glucose threshold logic, CGM-quality
  bailouts — `determine-basal.js` ~420–1620, `basal-set-temp.js`), because removing the
  JS must not remove the guardrails.

---

## 2. Target architecture

```
 new CGM value delivered (event-driven; no cycle without a new value)
   │
   ▼
┌─────────────────────────────────────────────────────────────────────┐
│                          DosingEngine                               │
│                                                                     │
│  ┌────────────────┐   ┌──────────────┐   ┌──────────────────────┐   │
│  │ StateEstimator │──►│  Dynamics    │──►│  Controller (MPC     │   │
│  │ (CGM-lag       │   │  Model       │   │  search over         │   │
│  │  compensation, │   │ (Core ML,    │   │  candidate insulin   │   │
│  │  sensor QC)    │   │  quantile    │   │  plans, asymmetric   │   │
│  └────────────────┘   │  forecasts)  │   │  ±15 cost)           │   │
│         ▲             └──────▲───────┘   └──────────┬───────────┘   │
│         │                    │                      │               │
│  ┌──────┴────────────────────┴───────┐    proposed rate + SMB       │
│  │ AdaptationStack (hourly-evolving, │              ▼               │
│  │ bounded params + residual model)  │   ┌──────────────────────┐   │
│  └───────────────────────────────────┘   │   SafetyEnvelope     │   │
│                                          │   HARD CAPS — always │   │
│         every stage writes to            │   on, not toggleable │   │
│  ┌───────────────────────────────────┐   └──────────┬───────────┘   │
│  │ DecisionAudit (5W1H record/cycle) │◄─────────────┤               │
│  └───────────────────────────────────┘              ▼               │
└─────────────────────────────────────────── Determination → pump ────┘
        anomaly / low confidence / stale data
                  └──► fallback: oref → zero-temp + profile basal + alert
```

### 2.1 Cadence and CGM latency

**Requirement:** the loop runs on CGM event delivery — one cycle per newly delivered
value, **no re-cycle without a new value**. The sensor's ~5-minute delivery interval
is therefore the loop cadence; CGM data still reflects blood glucose ~10–15 minutes
ago and must be compensated for.

* **Strictly event-driven trigger.** A cycle starts only when the CGM pipeline
  delivers a reading that is *new* (deduplicated by timestamp/value against the last
  processed reading — backfill re-deliveries and duplicate pushes do not trigger
  cycles). Today's loop triggering (`APSManager.loop()` via `DeviceDataManager`
  heartbeat, 3-min minimum interval in `canStartNewLoop`) is reworked so pump
  heartbeats and timers never start a dosing cycle on their own; they only refresh
  pump state. Manual triggers (user-initiated "run cycle now", carb entry, bolus
  entry) re-evaluate using the newest already-delivered value and are marked as such
  in the audit record.
* **Silence decays safely.** Because there is no re-cycle without a new value, every
  dose must have a bounded lifetime: temp basals are issued with ≤30-min durations, so
  a sensor going quiet means the last temp expires and the pump reverts to profile
  basal on its own — no software action required. SMBs are only ever issued within a
  cycle, so no new value ⇒ no new SMB, inherently. A **non-dosing watchdog** (alert
  only — it never doses, so it doesn't violate the event-driven rule) raises
  escalating notifications when no new value has arrived for 10/20/30 min, and the
  independent CGM urgent-low alarms remain untouched.
* **StateEstimator — lag compensation.** A lightweight filter (Kalman-style) fuses the
  delayed CGM sequence with known insulin activity and carb absorption to estimate
  *current* blood glucose and rate of change, not 15-minutes-ago glucose. The dynamics
  model is trained on estimator output, so the whole stack reasons in "now" terms.
  The estimator also owns sensor QC: gap handling after an outage (a burst of
  backfilled values triggers *one* cycle on the newest, with history repaired),
  compression-low detection (sudden implausible drop vs. IOB context), and
  calibration-jump detection. Estimated-vs-measured divergence is logged per cycle;
  beyond a band it triggers fallback (§2.6).
* **Envelope rule on data age:** a dosing cycle whose triggering value is older than
  10 min by the time the decision is made (processing backlog, backfill) may only
  reduce or hold delivery — never issue an SMB or raise a temp.

### 2.2 Dynamics model (learned)

* **Task:** given the last 6 h of estimated state and a *candidate* insulin plan,
  predict glucose trajectories for the next 4 h as p10/p50/p90 quantiles at 5-min
  steps, plus a meal/absorption disturbance signal (learned successor to UAM) so
  unannounced carbs surface as a rising disturbance the controller reacts to.
* **Features per 5-min frame:** estimated BG + deltas (15/30/60 min), IOB decomposed
  into future-activity buckets, COB with absorption estimate, basal and bolus delivery
  per frame, time-of-day/day-of-week encodings, active override/temp target, TDD
  stats. (This is the tuple Trio already assembles: `AlgorithmGlucose`,
  `PumpEventDTO`, `TrioCustomOrefVariables`.)
* **Architecture:** small sequence model (temporal conv or GRU), ~10⁵–10⁶ params,
  quantile-regression heads (pinball loss, extra weight on the low quantile). Trained
  in PyTorch, exported to Core ML, <50 ms inference on iPhone.

### 2.3 Controller (MPC)

Each cycle: enumerate candidate plans (temp-basal rates 0→cap in pump increments ×
SMB sizes 0→cap), roll each through the dynamics model, score over the 4-h horizon:

* **hard reject** any plan whose p10 trajectory crosses the hypo threshold;
* heavy quadratic penalty below `target − 15` (on p50);
* moderate penalty above `target + 15`, growing with excursion size and duration;
* small penalty on aggressiveness and dose-to-dose variability (anti-oscillation).

Minimum-cost plan goes to the SafetyEnvelope. Same *shape* as oref (MPC over a model);
the replacement is a personalized learned model and an explicit search — which is what
makes each decision fully auditable (§2.5).

### 2.4 SafetyEnvelope — hard caps (always on)

Pure-function Swift module, exhaustive unit + property-based tests ("no possible model
output produces a dose above cap"). **Not toggleable. Not adaptable. Not writable by
the evolution pipeline.** Cap values are user settings (reusing `Preferences` /
`PumpSettings`), changeable only by explicit human action in the settings UI, and every
cap change is itself written to the audit log.

| Cap | Rule |
|---|---|
| **Max IOB** | Reject any plan pushing projected IOB past cap; clamp to the residual headroom |
| **Max basal rate** | `min(maxBasal, maxDailyMultiplier × maxDailyBasal, currentMultiplier × currentBasal)` |
| **Max SMB per dose** | Absolute units cap AND `maxSMBBasalMinutes`-equivalent cap; floored to pump increment |
| **Min SMB interval** | No SMB within N min of any bolus |
| **Max insulin per rolling hour** | Basal-above-profile + SMBs summed over 60 min ≤ cap |
| **Max insulin per rolling 24 h** | TDD ceiling as a multiple of recent average TDD |
| **Low-glucose suspend** | Estimated or p10-predicted BG below threshold ⇒ zero-temp, no SMB, unconditionally |
| **Escalation limiter** | Consecutive-cycle dose increases rate-limited |
| **Data-quality gate** | Stale (>10 min for dosing), calibrating, flat-lined, implausible-jump CGM ⇒ reduce/hold only |
| **Pump-state guards** | Suspended, bolusing, manual temp, reservoir empty ⇒ no ML action (existing `verifyStatus()`) |

Ordering: controller output → per-dose caps → rolling-window caps → LGS override →
pump quantization. Every clamp that actually fires is recorded in the audit record
with before/after values.

### 2.5 DecisionAudit — who / what / where / when / why / how

One structured record per cycle (including no-action and fallback cycles), persisted
to CoreData (`MLDecisionAudit` entity), uploaded to Nightscout (compact form in the
device-status `reason`, full form as a treatment note), exportable as JSONL, and
browsable in-app (decision list → detail view).

| Field | Contents |
|---|---|
| **Who** | Deciding component + exact versions: engine version, model weights checksum/version, AdaptationStack parameter snapshot (each scalar's current value), SafetyEnvelope code version, active toggle states, cap values in force |
| **What** | Proposed action (rate, duration, SMB) *and* enacted action, plus the delta if the envelope clamped it; explicit `NO_ACTION` / `HOLD` / `SUSPEND` outcomes |
| **Where** | Path taken through the pipeline: ML / oref-fallback / zero-temp-fallback; which stage terminated the decision (e.g. "envelope: LGS override") |
| **When** | Timestamps: cycle trigger (new CGM value vs. manual/carb/bolus re-evaluation), the triggering reading's sensor time + delivery time + age at decision, estimator output time, decision time, enactment time + pump ack |
| **Why** | Cost breakdown of the chosen plan vs. runner-up and vs. zero-action: predicted p10/p50/p90 trajectories for each, which constraint(s) were binding, disturbance-signal level, estimator confidence, and a generated one-sentence human summary ("SMB 0.4 U: p50 reaches 172 in 40 min without action; p10 stays >85 with it") |
| **How** | Candidate-set summary (ranges searched, count), inference latencies, input feature hash (exact reproducibility: same inputs + same versions ⇒ same decision, verified by a replay tool in the training repo) |

The audit record is written *before* enactment and finalized with the pump ack, so a
crashed cycle still leaves evidence of what was intended.

### 2.6 Toggle matrix

Every component is independently toggleable in a dedicated "ML Engine" settings pane.
Each toggle has a defined degraded behavior — flipping any toggle can only make the
system *more* conservative, and every toggle change is audit-logged.

| Component | Off ⇒ behavior |
|---|---|
| ML engine (master) | Full oref, exactly as today |
| ML SMBs | ML sets temp basals only; SMB = 0 |
| ML temp basals | ML issues SMBs only; basal follows profile |
| StateEstimator lag compensation | Raw CGM values used as-is (decisions reason on delayed glucose; controller behaves more conservatively) |
| Disturbance/UAM signal | Controller assumes announced carbs only (more conservative dosing on rises) |
| Hourly adaptation (fast loop) | Adaptation scalars frozen at 1.0 / last-reviewed values |
| Weight promotion (slow loop) | Champion model pinned; new weights accumulate but never activate |
| Shadow logging of oref | ML doses without the parallel oref comparison record (keep ON) |
| **SafetyEnvelope / hard caps** | **No toggle exists. Always on.** |
| **Fallback ladder** | **No toggle exists. Always on.** |

### 2.7 Fallback ladder (always armed)

```
ML healthy ─────────────────────────► ML doses
model missing / OOD input / p90−p10 too wide /
  live prediction error > band / watchdog timeout ──► oref doses (logged)
oref also unavailable ──► cancel temp, profile basal, alert
CGM invalid beyond bridging window ──► reduce/hold only, then existing stale behavior
```

"Live prediction error" = rolling comparison of the model's 30-min-ago predictions vs.
what actually happened; drift beyond a set RMSE band demotes the ML for that cycle and
counts toward an automatic stage-down (§5).

---

## 3. Hourly evolution — the AdaptationStack

**Requirement:** the model evolves hourly. Done as three tiers, so speed of change is
inversely proportional to blast radius. Every tier's current values are in every audit
record, so "which version of the system decided this" is always answerable.

| Tier | Cadence | What changes | Bounds / gate |
|---|---|---|---|
| **T1 — Residual corrector** | Every cycle (5 min) | A bias/slope correction on the model's short-horizon forecast, fitted to the last 3 h of prediction residuals (compensates site aging, sensor drift, day-effects within hours) | Correction magnitude hard-clamped (e.g. ±20 mg/dL at 1 h equivalent); can only shift *predictions*, never touch caps |
| **T2 — Sensitivity adaptation** | **Hourly** | A small set of named, interpretable scalars: overall sensitivity ratio (autosens successor), meal-absorption speed, basal-need bias; refit from the last 24–48 h | Each scalar hard-clamped (e.g. sensitivity ∈ [0.7, 1.3]); update step per hour limited (≤5%/h) so no single bad hour swings dosing; clamp hits are audit-flagged |
| **T3 — Weight retraining** | Continuous pipeline; **promotion whenever gates pass** (can be as often as hourly if compute allows, realistically daily) | Full model weights retrained on all data through the last hour | Promotion only after automated gate suite: backtest vs. current champion on newest data, hypo-safety regression (zero would-have-dosed-in-a-low events), simulator stress suite, calibration check on the low quantile. Fail ⇒ champion keeps running. Every promoted version retained for instant rollback |

* T1+T2 give genuine hour-scale evolution *on-device* with bounded, interpretable,
  individually-toggleable parameters — this is what safely satisfies "evolve hourly."
* T3 runs off-device (Mac or private CI pulling exports/Nightscout). The app loads
  signed, checksummed `.mlmodelc` versions; the champion version is pinned, displayed
  in settings, and stamped into every audit record.
* **Invariant:** no tier can modify the SafetyEnvelope, cap values, or the fallback
  ladder. Evolution can stall (gates failing); it can never regress silently.

---

## 4. Phased build

**Phase 1 — Foundations (build now, useful regardless):**
`MLDataExporter` (5-min frames from `GlucoseStored`, `CarbEntryStored`,
`PumpEventStored`, `TDDStored`, `OrefDetermination`/`Forecast`; JSONL via
share sheet; Nightscout as deep-history source) · `SafetyEnvelope` module with the
oref JS safety cases ported as unit-test fixtures · `DosingAlgorithm` protocol with
`OrefAlgorithm` wrapping the existing path unchanged · `DecisionAudit`
entity + logging (wired into the *oref* path first — audit visibility starts before
any ML doses) · CGM-event-only loop trigger rework (dedupe, no cycle without a new
value, non-dosing silence watchdog) · versioned feature schema shared Python↔Swift with
golden-file parity tests.

**Phase 2 — Offline model:** training repo under `ml/`; dataset builder; StateEstimator
prototyped offline; dynamics model; backtest harness replaying history frame-by-frame.
**Gate to proceed:** beats oref's stored `predBGs` at 30/60/120 min on held-out weeks,
no degradation in the low-glucose region, low-quantile calibration conservative.
Simulator stress suite (simglucose/UVA-Padova-style cohort): meals, exercise,
compression lows, dropouts, occlusions.

**Phase 3 — Shadow mode (≥4–6 weeks runtime):** `MLAlgorithm` integrated; toggle
oref / ML-shadow / ML-active (default oref). Both algorithms run each cycle; oref
doses; both determinations + full audit records persisted and uploaded for care-team
review. **Promotion gates:** zero cycles where ML would have dosed during an actual
low; live 30/60-min RMSE beats oref's; every large dose divergence reviewed and
explained.

**Phase 4 — Staged activation (care-team-paced, ≥2 weeks/stage):**
A: temp basals only, conservative caps → B: SMBs at 50% of cap → C: full authority
within the envelope. Advance criteria: tight-range % non-inferior, time-below-range
not increased, no envelope-clamp pattern suggesting the model *wanted* to overdose.
Auto stage-down triggers: any severe low; two consecutive nights below band; clamp or
fallback frequency above threshold.

**Phase 5 — Steady state:** AdaptationStack live (T1/T2 on-device hourly, T3 pipeline
gated), audit browser in-app, weekly care-team data review.

---

## 5. Testing matrix

| Layer | Test |
|---|---|
| SafetyEnvelope | Exhaustive unit + property-based tests (fuzz model outputs: dose > cap unreachable); oref JS safety cases as fixtures; rolling-window cap edge cases (DST, clock changes) |
| StateEstimator | Replay vs. raw-BG holdout; compression-low and dropout scenario fixtures |
| Feature pipeline | Golden-file parity Python ↔ Swift |
| Dynamics model | Backtest RMSE gates vs. oref predBGs; low-region calibration |
| Controller | Simulator scenario suite; replay of worst historical days; anti-oscillation checks |
| AdaptationStack | Clamp tests per tier; adversarial residual injection (bad hour of data cannot move T2 scalars past step limit) |
| Audit | Round-trip: decision replayed from audit record alone reproduces identical output (same versions + feature hash ⇒ same dose) |
| Integration | Fault injection: kill model mid-cycle, corrupt input, CGM silence (verify temp expiry to profile basal + watchdog alerts, no phantom cycles), duplicate/backfilled CGM delivery (exactly one cycle per new value) — verify fallback ladder and audit completeness |
| Rollback | One-tap revert to oref and one-version model rollback verified on-device before every stage advance |

---

## 6. Personal-safety operating rules (with care team)

* Rescue meds staged and in-date; support team knows the current stage and the revert
  procedure (Settings → ML Engine → master toggle off).
* Stage advances only after joint data review — never solo, never mid-week.
* CGM urgent-low alarms remain fully independent of this system.
* Severe low or two consecutive nights below band ⇒ automatic stage-down pending review.
* Nightscout keeps uploading suggested + enacted + audit summaries for remote
  visibility.

---

## 7. Implementation status (Phase 1)

Built:

1. ✅ `SafetyEnvelope` (`Trio/Sources/APS/MLEngine/SafetyEnvelope.swift`) — full cap
   stack with oref formulas ported; unit + seeded property-based tests in
   `TrioTests/SafetyEnvelopeTests.swift`.
2. ✅ `DecisionAudit` (`.../MLEngine/DecisionAudit.swift`) — 5W1H record + JSONL
   store (Documents/decision_audit/, 90-day retention), observing every oref
   determination via `DeterminationObserver`; registered in ServiceAssembly and
   started at app launch. (JSONL instead of a CoreData entity for v1 — additive,
   no store migration; a CoreData mirror can follow once the record shape settles.)
3. ✅ `DosingAlgorithm` protocol + `OrefAlgorithm` wrapper (`.../MLEngine/DosingAlgorithm.swift`).
4. ✅ `MLDataExporter` (`.../MLEngine/MLDataExporter.swift`) — raw JSONL event export
   (glucose/carbs/pump/determinations), registered in APSAssembly.
5. ✅ `ml/` training scaffold — schema, dataset builder (5-min frames + labels),
   insulin curves, baselines, backtest harness, promotion gates, torch-guarded
   quantile-TCN skeleton; 23 passing stdlib tests (`python3 -m unittest discover -s ml/tests`).

6. ✅ CGM-event-only trigger (§2.1) — `canStartNewLoop` now requires a glucose value
   newer than the persisted `lastLoopGlucoseDate` (claimed at cycle start: one cycle
   per value, deduped against backfill/duplicate delivery); pump heartbeats and
   timers only refresh pump state. Manual refresh and manual-temp-basal-end
   re-evaluate on the newest already-delivered value via `manualCycleRequested`.
7. ✅ `CGMSilenceWatchdog` (`.../MLEngine/CGMSilenceWatchdog.swift`) — non-dosing
   escalating notifications at 10/20/30 min without a newly stored value,
   pre-scheduled on every store so they fire while the app is suspended.

8. ✅ "ML Data & Audit" settings screen (`Trio/Sources/Modules/MLEngineData/`) —
   training-data export with share sheet (30/60/90 days) and a decision-audit file
   browser with per-file sharing; reachable from Settings → ML Engine and via
   settings search.

9. ✅ StateEstimator prototype (`ml/trioml/estimator.py`) — 2-state Kalman filter
   with lag-aware measurement model, QC (implausible jumps, duplicates, gap
   staleness), tuned on synthetic sweeps; validates against real exports next.

10. ✅ Zero-basal profile support — oref sources patched + bundles rebuilt
    (profile validation, maxSafeBasal zero-term fallback, scale_basal for SMB
    caps/durations), mirrored in SafetyEnvelope; functionally verified in Node.
11. ✅ Scheduled delivery caps (`.../MLEngine/DeliveryCapSchedule.swift`, editor at
    Settings → ML Engine → Scheduled Delivery Caps) — time-of-day windows with
    Max Basal + Max SMB ceilings (0/0 = no insulin from the loop). The loop runs
    every cycle regardless; enforcement happens at enactment in
    `APSManager.enactDetermination`, including issuing a capped temp over running
    temps/scheduled basal. Windows may wrap midnight; overlaps combine to the most
    restrictive cap. Manual boluses unaffected.

12. ✅ StateEstimator validated against a real export (`ml/validate_estimator.py`:
    estimate at t vs. the reading delivered at t + lag, reference offset fixed
    while the assumed lag sweeps). **Finding: on this G7 data no assumed lag
    (0–15 min) beats the raw readings** — est RMSE 13.0–14.1 vs raw 11.9 mg/dL
    overall, same ordering on the moving-glucose subset — consistent with the
    sensor already smoothing and lag-compensating in firmware. Consequence:
    the Swift port is deferred and the lag-compensation toggle (§2.6) should
    default off; the dynamics model trains on raw readings. Revisit with a
    sensor-specific lag model or a sensor that exposes raw values.
13. ✅ Dynamics model implemented (`ml/trioml/features.py`, `ml/trioml/model.py`,
    `ml/train_dynamics.py`) — quantile TCN (~20k params, p10/p50/p90
    trajectories at 5-min steps over 4 h, ordering by construction, pinball
    loss ×3 on p10) conditioned on 6-h history + the insulin plan (delivered
    insulin at training; a candidate plan at controller time). Residual
    formulation: it predicts deltas from current glucose. First real-data run
    (14-day export, 3,567 samples, newest 3 days held out): candidate RMSE
    19.5/27.5/31.1 mg/dL at 30/60/120 min vs persistence 21.8/34.7/52.1;
    p10 miss rate 0.07 (gate ≤ 0.12); every gate passes, stable across seeds.
    Caveats: the held-out window has zero readings below 80, so the low-region
    gate is vacuous on this export — more weeks of data must accumulate before
    that gate means anything; and the export lacks oref `predBGs`, so the
    Phase 2 "beats oref" bar is still open (baselines are the enforced bar).

14. ✅ `predBGs` in the export — `MLDataExporter` now writes each determination's
    stored forecast curves (iob/zt/cob/uam, 5-min steps from the determination
    time) as an optional additive field (schema stays v1; older exports remain
    valid). `trioml.oref` turns them into the champion forecaster (scenario:
    cob while COB > 0, else uam, else iob — never the zero-temp counterfactual)
    and `train_dynamics.py` gates the candidate against oref on exactly the
    (frame, horizon) pairs oref predicted. The existing corpus predates the
    field, so this gate first bites on the next in-app export.
15. ✅ Core ML export (offline half) — `ml/export_coreml.py` converts a
    promote-verdict artifact to `DynamicsModel.mlpackage` (the TCN now uses
    explicit causal left-padding so the trace is free of dynamic-shape ops),
    refuses any candidate whose gate verdict wasn't promote, stamps the torch
    weights checksum into the package metadata, and emits seeded
    torch-output verification cases. Linux cannot execute Core ML, so the
    app/Mac side must replay those cases through the compiled model within
    tolerance before the artifact is trusted.

Next:

16. On-device Core ML verification replay, then the shadow-mode `MLAlgorithm`
    recording p10/p50/p90 alongside oref every cycle (no dosing influence).
17. Re-export from the app (now with predBGs) and run the candidate-vs-oref
    gate for real; keep archiving exports to grow the low-region evidence the
    vacuous gate is waiting for.
