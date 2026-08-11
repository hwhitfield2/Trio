# Diluted Insulin (U-10 / U-20 / U-50) Support

## What this feature does

Trio can drive a pump whose reservoir contains **diluted insulin** — e.g. U-10,
which is 1 part U-100 insulin mixed with 9 parts diluent (a 300 U reservoir
filled with 30 U of insulin and 270 U of saline). Dilution is used for very
small insulin needs (typically young children), and also improves dosing
resolution: a pump that meters 0.05 U volume steps delivers 0.005 U of actual
insulin per step with U-10.

Enable it in **Settings → Units and Limits → Insulin Dilution**. The setting is
`TrioSettings.allowDilution` plus `TrioSettings.insulinConcentration`
(1 = U-100, 0.5 = U-50, 0.2 = U-20, 0.1 = U-10). The effective factor is
exposed as `TrioSettings.insulinConcentrationFactor` (and
`...FactorDecimal`) in `Trio/Sources/Helpers/InsulinConcentration.swift`;
it is always 1 unless dilution is explicitly enabled and the stored value is
sane.

## The core convention — read this before touching dosing code

**Every insulin quantity inside Trio is in actual insulin units (U-100
equivalents).** Basal profiles, ISF, carb ratio, boluses, SMBs, temp basal
rates, IOB, TDD, max bolus / max basal, oref inputs and outputs, Core Data
pump history, Nightscout/Tidepool/HealthKit uploads — all actual insulin.

**The pump meters fluid volume and always believes it is delivering U-100.**
Conversion happens only at the pump boundary:

| Direction | Conversion | Where |
| --- | --- | --- |
| Commands → pump (bolus, temp basal) | ÷ factor | `APSManager.enactBolus`, `enactTempBasal`, `performBolus`, `performBasal` |
| Rounding to pump-supported steps | round in volume space | `PumpManager.roundToSupportedBolusVolume(units:insulinConcentration:)` / `roundToSupportedBasalRate(unitsPerHour:insulinConcentration:)` |
| Delivery limits → pump | ÷ factor | `PumpSettings.pumpDeliveryLimits(insulinConcentration:)` (DeviceDataManager, UnitsLimits/Nightscout/AlgorithmAdvanced providers) |
| Limits reported by pump → storage | × factor | `PumpSettings.applyingPumpReported(limits:insulinConcentration:)` |
| Basal schedule → pump | ÷ factor | BasalProfileEditor / AutotuneConfig / SettingsExport sync, PumpConfig & Home `PumpInitialSettings` |
| Pump history events → Core Data | × factor | `PumpHistoryStorage.storePumpEvents` |
| Active temp basal state → oref | × factor | `APSManager.fetchCurrentTempBasal` |
| Supported increments → preferences/UI | × factor | `bolusIncrement` (DeviceDataManager, Onboarding), `supportedBasalRates` (BasalProfileEditor) |

**Deliberately *not* converted:** reservoir readings. They describe the fluid
physically present in the reservoir and match the pump's own UI and
low-reservoir alerts, so they stay in volume units everywhere (Home header,
Nightscout status).

Also not converted: anything inside the pump-manager libraries themselves
(OmnipodKit, DanaKit, MedtrumKit, MinimedKit, TandemKit). Their own settings
screens, progress reporters and alerts all speak volume units.

## Changing the concentration re-programs the pump

When the user toggles dilution or picks a different concentration,
`UnitsLimitsSettings.StateModel.handleConcentrationChange` calls
`Provider.resyncPumpInsulinConcentration()`, which rescales on the pump:

1. the `bolusIncrement` preference (actual insulin units),
2. the pump's delivery limits,
3. **the pump's programmed basal schedule** — critical, because the pump falls
   back to its internal schedule whenever the loop is not running; without the
   rescale it would deliver a factor of 2–10 too little (or too much) insulin.

If that sync fails, the settings screen shows a red warning telling the user
not to rely on automated dosing until profile and limits are re-saved with the
pump connected.

## Practical consequences (worth repeating to users)

- With U-10, the pump's *maximum* deliverable amounts shrink 10×: an Omnipod
  capped at 30 U/hr of volume can deliver at most 3 U/hr of actual insulin;
  its 30 U max bolus becomes 3 U.
- Dosing resolution improves by the same factor (0.05 U volume step → 0.005 U
  insulin).
- The reservoir display shows fluid volume, not insulin. A 200 U pod filled
  with U-10 holds 20 U of actual insulin.
- The setting must match the reservoir contents. Enabling U-10 while the
  reservoir still holds U-100 causes 10× overdelivery the moment the pump is
  re-programmed; the UI warns about this and the change should coincide with a
  reservoir/pod change.

## Tests

`TrioTests/InsulinConcentrationTests.swift` pins the factor semantics, the
option ↔ factor mapping, and the delivery-limit conversions.
`TrioTests/DeliveryLimitsSyncTests.swift` exercises the shared
`pumpDeliveryLimits` helper at factor 1.
