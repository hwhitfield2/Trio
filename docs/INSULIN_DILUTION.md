# Running Diluted Insulin (U-10) — Volume-Units Convention

## The decision

This fork runs diluted insulin (e.g. U-10: 1 part U-100 insulin + 9 parts
diluent, so a 300 U reservoir holds 30 U of actual insulin) using the
**volume-units convention**: Trio, the pump, and every number on screen all
speak *pumped volume units*, exactly as if the fluid were U-100.

There is deliberately **no conversion layer anywhere in the code.** An earlier
implementation converted between actual insulin units and pump volume at the
pump boundary (commit `880cd73`, reverted); it was removed because the owner
prefers that every value in Trio match the pump's own screens 1:1 — if the
pump is about to push 0.47 U of volume, Trio shows 0.47, and any mismatch is
immediately visible. With a conversion layer, verifying correct behavior
required mentally un-scaling numbers; without one, the loop's arithmetic is
trivially auditable against the pump.

The closed loop is unit-agnostic: as long as basal rates, ISF, carb ratio,
boluses, IOB, and limits all share the same unit, oref's math is identical.
"One unit" throughout this app simply means one *pumped* unit — with U-10,
that is 0.1 U of actual insulin.

## Entering settings for U-10 (multiply/divide by the dilution factor of 10)

All therapy settings are entered in pumped units:

| Setting | Actual-insulin value | Enter in Trio (U-10) |
| --- | --- | --- |
| Basal rate | 0.05 U/hr | **0.5 U/hr** |
| ISF | 500 mg/dL per U | **50 mg/dL per U** |
| Carb ratio | 100 g per U | **10 g per U** |
| Max bolus | 1 U | **10 U** |
| Max basal | 0.3 U/hr | **3 U/hr** |
| Max IOB | 1.5 U | **15 U** |
| Meal bolus for 30 g | 0.3 U | **3.0 U** |

General rule for a dilution of 1 part insulin to N−1 parts diluent (U-100/N):
multiply amounts and rates by N; divide ISF and carb ratio by N.

Everything downstream is automatically consistent: IOB, COB dosing, TDD
statistics, autotune, Nightscout/Tidepool/HealthKit uploads, and the ML
forecaster all see pumped units. (External viewers like Nightscout will
display pumped units too — divide by 10 to discuss actual insulin with a
care team.)

## Why this also solves the small-dose resolution problem

The pump's mechanical increments are unchanged (0.05 U volume per pulse), but
each pulse now carries 1/10 the insulin. A real basal of 0.05 U/hr — entered
as 0.5 U/hr — is delivered as ten 0.05 U pulses spread across the hour
instead of one, and the Tandem microbolus-basal engine
(`TandemMicrobolusBasal.swift`) accrues at 0.5 U/hr and fires a ~0.08 U pulse
roughly every 10 minutes rather than one pulse per hour. Effective dosing
resolution improves 10× with no code involved.

## Safety notes

- **The reservoir contents and the entered settings must agree.** Switching
  between U-100 and U-10 means re-entering basal profile, ISF, CR, and all
  limits scaled by 10 — at the same time as the reservoir/pod change.
  There is no app setting to flip; the profile *is* the convention.
- Pump hardware maxima are unchanged in volume terms and therefore shrink
  10× in actual insulin (a 30 U/hr volume cap = 3 U/hr real insulin) — but
  since everything is entered in volume units, the limits behave exactly as
  displayed.
- The unused `TrioSettings.allowDilution` / `insulinConcentration` fields
  remain reserved stubs; nothing reads them. If a future contributor is
  tempted to wire them up, read the paragraph above about why the conversion
  layer was removed, and see commit `880cd73` and its revert for the full
  boundary map that a conversion approach requires.
