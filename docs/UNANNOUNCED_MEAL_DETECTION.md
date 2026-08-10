# UAM+ — Unannounced Meal Detection & Trend-Aware Eventual BG

Changes to `trio-oref/lib/determine-basal/determine-basal.js` (rebuilt into
`Trio/Resources/javascript/bundle/determine-basal.js`) addressing two gaps:

1. **Partially logged meals go undetected.** Log the sandwich but not the
   smoothie and oref attributes all observed glucose impact to the logged
   carbs, decays its predictions on a fixed schedule, and never doses for the
   unlogged intake.
2. **Eventual BG reflects oref's assumptions, not the data.** oref assumes
   observed deviations decay to zero within the hour, so it can show an
   eventual BG *below* current BG while glucose is steadily rising.

## Detection (UAM+)

Runs every loop cycle using the deviation history the meal module already
computes (`meal_data.allDeviations`, last ~30–45 min, 5-min buckets). All of
the following must hold:

| Gate | Meaning |
|------|---------|
| ≥75 % of recent deviations positive, avg ≥ max(3, min_5m_carbimpact / 2) mg/dL/5m | sustained unexplained glucose impact, not noise |
| currentDeviation ≥ 85 % of maxDeviation | absorption is not tapering — still ramping or holding at peak |
| COB cannot explain it | remaining logged COB too small to sustain the observed impact even if it all absorbed within 30 min, **or** ≥70 % of logged carbs already absorbed, **or** COB = 0 |
| BG above target | never boosts insulin while below target (rebounds from lows are excluded) |
| UAM enabled | feature rides on the existing `enableUAM` preference |

When all gates pass:

- **UAM predictions hold the observed carb impact flat for 30 min** before
  applying oref's normal decay (unlogged carbs keep absorbing; an immediate
  decay understates the impact).
- **The `maxCOBPredBG` cap on `minPredBG` is lifted.** oref normally refuses
  to trust UAM above what the COB prediction line supports ("if the COB line
  falls off a cliff…"); when the COB line is *known* to be incomplete that cap
  is exactly wrong.
- The estimated unlogged carbs are surfaced in the reason string:
  `UAM+: unannounced carbs detected (~9g unlogged)`.

## Trend-aware eventual BG

Independent of detection (only requires sustained deviations of ≥2 mg/dL/5m
in either direction), an alternative destination is projected from the data:

```
trendEventualBG = naive_eventualBG            // BG − IOB × ISF (insulin-only landing)
                + avgRecentDeviation × carry  // observed run rate, triangular decay
                                              // over 60 min (90 min when UAM+ active)
```

- Rising: used when **higher** than the model's eventualBG.
- Falling: used when **lower** — the displayed destination also stops being
  optimistic on sustained drops, and low-temping gets correspondingly stronger.
- Logged carbs still enter through the existing max() against the COB
  prediction tail, and insulin through `naive_eventualBG` — insulin vs carbs
  vs run rate, each from its own source.
- Surfaced in the reason string: `trend eventualBG 165 (run rate +4.5 mg/dL/5m)`.

## What did NOT change

Every existing guardrail still applies **after** these changes:

- `minGuardBG < threshold` → SMBs disabled, zero temp (scenario-tested).
- SMB size caps (`maxSMBBasalMinutes` / `maxUAMSMBBasalMinutes`), `max_iob`,
  `smb_delivery_ratio`, SMB interval, `maxSafeBasal`.
- maxDelta (calibration-jump) SMB disable, CGM staleness/noise early exits.
- The Swift `SafetyEnvelope` still independently vets every proposed dose.
- Dosing is still driven by `minPredBG` (post-insulin-peak minimum of the
  prediction curves), not by the displayed eventual BG directly.

## Verification

`trio-oref/tests/unannounced-meal.test.js` — run with
`NODE_PATH=<dir with lodash> node trio-oref/tests/unannounced-meal.test.js`.

Key result (scenario 1b, mirroring the reported screenshot — logged carbs
expired, BG 152 rising +4, small IOB): baseline oref showed eventualBG 121
(a predicted *drop*) and delivered **no SMB**; with UAM+ the determination
shows eventualBG 161 and delivers a capped SMB. Falling/rebound/fresh-meal
scenarios are unchanged except the more honest eventual BG on sustained
falls, and the hypo-guard scenario still ends in a zero temp with no SMB.

The bundle was rebuilt with webpack 5 + terser (library `trio_determineBasal`
preserved) and verified bit-identical to the source on every scenario.
