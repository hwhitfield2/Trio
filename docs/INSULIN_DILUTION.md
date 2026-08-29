# Running Diluted Insulin (U-5/U-10/U-20/U-50)

## The convention

This fork supports pumping diluted insulin (e.g. U-10: 1 part U-100 insulin +
9 parts diluent, so a 300 U reservoir holds 30 U of actual insulin; U-5:
1 part + 19 parts, the strongest supported dilution) under one convention:

1. **Runtime is pumped volume units.** Every stored and runtime insulin
   quantity — boluses, SMBs, basal rates, IOB, TDD, pump history, oref inputs
   and outputs, delivery limits and caps, and the Nightscout/Tidepool/
   HealthKit uploads — is denominated in units of fluid the pump meters. If
   the pump pushes 5 U of volume, Trio (and everything downstream) shows 5 U.
   Every number matches the pump's own screens 1:1, so correct behavior is
   verifiable at a glance, and the loop's math contains **no conversion
   anywhere** — oref is unit-agnostic when all quantities share one unit.

2. **Therapy settings are pumped volume too, with the actual insulin as a
   caption.** The basal profile, ISF, and carb ratio editors, the Max Bolus /
   Max Basal / Max IOB limits, the scheduled delivery caps, the therapy ratio
   calculator, and the Autotune results screen all show the value the pump is
   programmed with. Nothing converts at the UI boundary; a basal row reading
   1.0 U/hr *is* the 1.0 U/hr on the pump.

   Because a prescription is written in actual insulin, each therapy value
   carries a caption naming it (`actualInsulinCaption`):

   - amounts and rates: `caption real = shown volume × factor`
   - per-unit ratios (ISF, CR): `caption real = shown volume ÷ factor`

   where `factor` is the concentration fraction (U-10 → 0.1). Convert your
   prescription once when you enter it, and check it against the caption: a
   care team's ISF of 500 typed into a field that wants 25 is a 20× under-
   correction, which is why the typed-entry field shows the caption live as
   you type, before you press Set. The editors also carry a banner naming the
   concentration.

The setting lives in **Settings → Units and Limits → Insulin Dilution**
(`TrioSettings.allowDilution` + `insulinConcentration`).

## What changing the setting does

Flipping the concentration (including toggling dilution on/off) rescales every
stored volume-unit therapy setting in place so its *real* meaning is
preserved, then re-programs the pump:

- basal profile ×, ISF ÷, carb ratio ÷, Max Bolus/Basal/IOB ×, delivery caps ×
  (by the ratio of old to new factor, with basal rates snapped to the pump's
  supported volume rates; any rate the pump clamps or floors to zero is
  called out in a warning),
- stored TDD statistics are rescaled in place so dynamic ISF and the ISF/CR
  calculator never mix volume scales across the switch,
- the switch is appended to a **concentration ledger**
  (`settings/insulin_concentration_history.json`, kept 45 days). Pump history
  is deliberately *not* rescaled — it records what the pump actually metered
  and must keep matching the pump's screens, Nightscout, and Apple Health — so
  the ledger is what re-expresses pre-switch events on the new scale as they
  enter the loop. It is applied at exactly two places, both computation
  boundaries: `OpenAPS.parsePumpHistory` (feeding IOB, COB, autotune, and
  determine-basal) and `TDDStorage.calculateTDD`. Several switches inside one
  window compose. Storage and display are untouched,
- storage is always rescaled first and consecutive changes are serialized —
  a pump failure can never leave the files half-migrated,
- the pump's fallback basal schedule and delivery limits are re-synced; a
  failure surfaces a **persistent** warning (it survives leaving the screen)
  with a Retry Pump Sync button,
- stored Autotune output is discarded — it was derived from history recorded
  in the old volume units — and regenerates from fresh data,
- profiles are re-uploaded to Nightscout/Tidepool.

Settings-backup **import** handles two scales at once, and keeps them apart:

- every backup records the concentration its therapy values are denominated in
  (`insulinConcentrationFactor`), independently of the Trio-settings section —
  a backup's therapy figures are pumped volumes, so the same numbers mean
  something 2–20× different on a device running a different concentration. An
  import that finds therapy data but no concentration is **refused**, because
  guessing is a dosing error in either direction;
- values the backup carries are converted from the backup's concentration to
  the one in force after the import, so a U-10 backup restored onto a U-100
  device keeps the same actual-insulin therapy (and says so in the summary);
- local data the backup does *not* replace — delivery caps, TDD statistics,
  autotune, and any therapy category the backup omits — is rescaled from the
  device's previous concentration instead, and the switch is added to the
  ledger;
- the imported basal profile is always stored even if re-programming the pump
  fails.

## oref's side

oref is unit-agnostic: with every quantity in the same unit, no conversion is
needed anywhere in the loop. That only holds if the algorithm contains no
constant denominated in insulin units, which is a property that has to be
maintained rather than assumed. Four places broke it and were fixed:

- **sanity floors.** ISF ≥ 0.2 mg/dL per pumped unit and CR ≥ 0.04 g per
  pumped unit, so legitimately diluted values no longer kill profile
  generation or COB math. These are absolute by design; they must sit below
  anything that can legitimately reach oref. The editors are themselves
  volume-denominated (ISF grid from 9, CR from 1 per pumped unit), so they no
  longer produce sub-unit values — but a settings-backup import, or a rescale
  of a profile authored under an older build, still can: a U-100 ISF of 9
  rescaled to U-5 stores 0.45, and a CR of 1 stores 0.05. Autotune can push a
  stored ISF lower still, to imported-minimum ÷ `autosens_max`
  (0.45 / 2 = 0.225), which the 0.2 floor admits. The autotune CR clamp
  is set *equal* to the CR floor (0.04) so a tuned CR can never fall below
  what profile generation accepts. Adding a stronger dilution means
  re-deriving every floor against both the editors and autotune's range. The
  trade-off of an absolute floor this low is real: junk in (0.04, 0.1) — e.g.
  an inverted carb ratio for real CRs of 10–25 g/U — is no longer rejected on
  an undiluted device, extending the band the old floor already admitted
  (0.1–1.0, the inverse of real CRs 1–10). No in-app editor can produce such
  values; the exposure is corrupted or hand-edited imports.
- **the SMB size cap.** `maxSMBBasalMinutes` worth of basal was rounded to
  0.1 U, which both let the cap exceed the setting (0.25 U of basal became a
  0.3 U ceiling) and floored it to *zero* — disabling SMBs entirely — for any
  basal rate under 0.1 U/hr. Now rounded to 0.001 U; deliverability is still
  enforced by flooring the microbolus to the pump's bolus increment.
- **ISF quantisation.** `sens` was rounded to 0.1 mg/dL per *pumped* unit,
  which under U-10 quantised the real ISF to 1 mg/dL steps — the one place
  where diluting made the algorithm coarser instead of finer. Now 0.001.
- **reported ISF/CR.** `rT.ISF` and `rT.CR` were display-rounded (whole
  mg/dL or 0.1 mmol/L; 0.1 g per pumped unit), but Trio's manual bolus
  calculator *divides* by both. Under U-5 the ISF editor minimum stores as
  0.45 per pumped unit and rounded to zero (mmol/L reached zero at U-10
  already), turning the bolus calculation into a division by zero. Both now
  report at 0.001, and the Swift calculator additionally refuses to divide by
  a non-positive determination value, falling back to the schedule value.

`trio-oref/tests/dilution-scale-invariance.test.js` pins this: it runs the
shipped **bundles** (not `trio-oref/lib`, which is informational) over the same
therapy expressed at U-100, U-50, U-20, U-10 and U-5 and asserts every insulin
output agrees in actual-insulin terms to within the undiluted run's own
granularity, and that diluting never delivers less. It also pins the floors:
an imported or rescaled U-5 therapy (stored ISF 0.45, CR 0.05) must generate a
profile and enter COB math. Run it with
`node trio-oref/tests/dilution-scale-invariance.test.js` — it needs nothing
installed.

Note the one quantity that is legitimately *not* scale-invariant: the pump's
bolus and basal increments. The pump meters the same 0.05 U of fluid whatever
the fluid contains, which is exactly why dilution improves dosing resolution.

## Example: U-10 with a real basal of 0.05 U/hr, ISF 500, CR 100

| Value | Shown everywhere (pumped) | Caption (actual insulin) |
| --- | --- | --- |
| Basal rate | 0.5 U/hr | 0.05 U/hr |
| ISF | 50 mg/dL per U | 500 mg/dL per unit |
| Carb ratio | 10 g per U | 100 g per unit |
| Max bolus | 10 U | 1 U |
| Meal bolus for 30 g | 3.0 U | — |
| IOB after that bolus | 3.0 U | — |

Every number in the app reads in pumped units. Amounts (boluses, IOB, TDD,
basal rates) divide by 10 to give actual insulin; ISF and carb ratio are *per*
unit, so they multiply by 10 instead. Deliveries carry no caption — only
therapy settings do, and there the caption does the arithmetic for you.

## Why dilution helps small-dose therapy

The pump's mechanical increments are unchanged (0.05 U volume per pulse), but
each pulse carries 1/10 the insulin with U-10 and 1/20 with U-5. A real basal
of 0.05 U/hr runs as 0.5 U/hr of volume under U-10 — ten pulses spread across
the hour instead of one. Effective dosing resolution improves by the dilution
factor; the editors accordingly display real-unit steps as fine as 0.0025 U
(and basal labels down to 0.00125 U/hr on pumps with 0.025 U increments).

The pump's hardware maxima shrink correspondingly in real terms: a 30 U/hr
volume cap can deliver at most 3 U/hr of actual insulin at U-10, and only
1.5 U/hr at U-5. The same goes for the pump's largest single bolus and its
reservoir: a 200 U pod holds 10 U of actual insulin at U-5. Check that the
therapy actually fits the hardware at the chosen dilution.

## Safety notes

- **The reservoir contents and the concentration setting must agree.** Change
  the setting at the same time as you fill a fresh reservoir/pod with the
  diluted insulin. A mismatch causes dosing that is 2–20× off.
- **Still prefer to switch with IOB near zero.** Pump history recorded before
  the switch keeps its old volume units on disk. The concentration ledger
  re-expresses those events for IOB, COB, TDD and autotune as they enter the
  loop, so a switch no longer produces a step change in IOB — but it only
  corrects the *arithmetic*. It cannot correct the therapy: the insulin already
  in the body came from the old reservoir, and the reservoir change and the
  setting change are never simultaneous to the minute. A near-zero-IOB switch
  remains the safe way to do it.
- Exported settings embed the concentration alongside the volume-unit
  profiles, so export/import round-trips consistently.
- **A Nightscout profile is read as pumped units.** That is right for a profile
  Trio uploaded and wrong for one written by a care team or another app, which
  is in actual insulin. The onboarding import step warns about this when
  dilution is on; check every imported value before looping.
- **Do not open a U-5 configuration with a Trio build that predates U-5
  support.** An older build's concentration picker does not know the 0.05
  factor and coerces it to U-100; merely opening its Units and Limits screen
  replays that coercion into storage *without* rescaling the stored therapy —
  a silent 20× mismatch. The loop math itself is unaffected until that screen
  is opened.
- History: an earlier implementation instead kept everything in actual
  insulin units and converted at the pump boundary (commit `880cd73`,
  reverted) — rejected because runtime numbers no longer matched the pump's
  screens. See that commit and its revert for the full boundary map a
  pump-boundary conversion requires.
