# Running Diluted Insulin (U-10/U-20/U-50)

## The convention

This fork supports pumping diluted insulin (e.g. U-10: 1 part U-100 insulin +
9 parts diluent, so a 300 U reservoir holds 30 U of actual insulin) with a
hybrid convention:

1. **Runtime is pumped volume units.** Every stored and runtime insulin
   quantity — boluses, SMBs, basal rates, IOB, TDD, pump history, oref inputs
   and outputs, delivery limits and caps, and the Nightscout/Tidepool/
   HealthKit uploads — is denominated in units of fluid the pump meters. If
   the pump pushes 5 U of volume, Trio (and everything downstream) shows 5 U.
   Every number matches the pump's own screens 1:1, so correct behavior is
   verifiable at a glance, and the loop's math contains **no conversion
   anywhere** — oref is unit-agnostic when all quantities share one unit.

2. **Therapy settings are entered and read in actual insulin units.** The
   basal profile, ISF, and carb ratio editors, the Max Bolus / Max Basal /
   Max IOB limits, the scheduled delivery caps, the therapy ratio calculator,
   and the Autotune results screen display real-insulin values and convert at
   the UI boundary (`InsulinConcentration.swift`):

   - amounts and rates: `displayed real = stored volume × factor`
   - per-unit ratios (ISF, CR): `displayed real = stored volume ÷ factor`

   where `factor` is the concentration fraction (U-10 → 0.1). You enter your
   prescription as your care team states it (ISF 500 mg/dL/U, basal
   0.05 U/hr) and Trio scales it for the dilution automatically.

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
- storage is always rescaled first and consecutive changes are serialized —
  a pump failure can never leave the files half-migrated,
- the pump's fallback basal schedule and delivery limits are re-synced; a
  failure surfaces a **persistent** warning (it survives leaving the screen)
  with a Retry Pump Sync button,
- stored Autotune output is discarded — it was derived from history recorded
  in the old volume units — and regenerates from fresh data,
- profiles are re-uploaded to Nightscout/Tidepool.

Settings-backup **import** runs the same migration when the backup carries a
different concentration than the device: delivery caps, TDD statistics, and
autotune (which are not part of the backup) are rescaled/reset to match the
imported concentration, and the imported basal profile is always stored even
if re-programming the pump fails.

oref's stored-unit sanity floors are widened for dilution (ISF ≥ 0.5 mg/dL
per pumped unit, CR ≥ 0.1 g per pumped unit, autotune CR clamp likewise), so
legitimately diluted values — e.g. real ISF 45 storing as 4.5 under U-10 —
no longer kill profile generation or COB math.

## Example: U-10 with a real basal of 0.05 U/hr, ISF 500, CR 100

| Value | You enter/see in editors (real) | Stored/pump/loop (volume) |
| --- | --- | --- |
| Basal rate | 0.05 U/hr | 0.5 U/hr |
| ISF | 500 mg/dL per U | 50 mg/dL per U |
| Carb ratio | 100 g per U | 10 g per U |
| Max bolus | 1 U | 10 U |
| Meal bolus for 30 g | — | shown/delivered as 3.0 U |
| IOB after that bolus | — | 3.0 U |

Deliveries, IOB, TDD, history, and all uploads read in pumped units — divide
by 10 to discuss actual insulin with a care team.

## Why dilution helps small-dose therapy

The pump's mechanical increments are unchanged (0.05 U volume per pulse), but
each pulse carries 1/10 the insulin with U-10. A real basal of 0.05 U/hr runs
as 0.5 U/hr of volume — ten pulses spread across the hour instead of one.
Effective dosing resolution improves 10×; the editors accordingly display
real-unit steps as fine as 0.005 U.

The pump's hardware maxima shrink correspondingly in real terms: a 30 U/hr
volume cap can deliver at most 3 U/hr of actual insulin.

## Safety notes

- **The reservoir contents and the concentration setting must agree.** Change
  the setting at the same time as you fill a fresh reservoir/pod with the
  diluted insulin. A mismatch causes dosing that is 2–10× off.
- **Switch with IOB near zero.** Pump history recorded before the switch is
  denominated in the old volume units; IOB spanning the switch is
  misinterpreted by the factor ratio for up to DIA hours. (TDD statistics
  and autotune are rescaled/reset automatically; live IOB from recent
  history is the one thing that cannot be.)
- Exported settings embed the concentration alongside the volume-unit
  profiles, so export/import round-trips consistently.
- History: an earlier implementation instead kept everything in actual
  insulin units and converted at the pump boundary (commit `880cd73`,
  reverted) — rejected because runtime numbers no longer matched the pump's
  screens. See that commit and its revert for the full boundary map a
  pump-boundary conversion requires.
