/*
  Scale-invariance tests for diluted insulin (docs/INSULIN_DILUTION.md).

  The whole dilution design rests on one claim: because Trio runs entirely in
  pumped volume units, oref never needs a conversion — it is unit-agnostic as
  long as every quantity shares one unit. That claim is only true if the
  algorithm contains no constant denominated in insulin units. It has been
  false before: the ISF/CR sanity floors were absolute (fixed), and the SMB
  size cap was rounded to 0.1 U (fixed), which both inflated the cap at U-100
  and floored it to zero for small basal rates.

  These tests run the SAME therapy twice — once undiluted, once as the exactly
  equivalent U-10 configuration with every insulin quantity x10, ISF and CR /10
  — and assert that every insulin output differs by exactly the same factor.
  They drive the MINIFIED BUNDLES Trio actually executes, not trio-oref/lib,
  because those are what ships. The bundles are self-contained (their
  dependencies are webpacked in), so this test needs nothing installed.

  Run with:  node trio-oref/tests/dilution-scale-invariance.test.js
*/

const fs = require('fs');
const vm = require('vm');
const path = require('path');
const assert = require('assert');

const BUNDLES = path.resolve(__dirname, '../../Trio/Resources/javascript');

let failures = 0;
let checks = 0;

function scenario(name, fn) {
    try {
        fn();
        console.log('  ok   ' + name);
    } catch (error) {
        failures += 1;
        console.log('  FAIL ' + name + '\n       ' + error.message);
    }
}

// --- bundle harness -------------------------------------------------------

function newContext() {
    const logs = [];
    const sandbox = { _consoleLog: (args) => logs.push(args.join(' ')) };
    vm.createContext(sandbox);
    return { sandbox, logs };
}

function load(sandbox, relativePath) {
    const file = path.join(BUNDLES, relativePath);
    vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
}

function makeProfile(config) {
    const { sandbox } = newContext();
    load(sandbox, 'prepare/log.js');
    load(sandbox, 'bundle/profile.js');
    load(sandbox, 'prepare/profile.js');
    sandbox.__config = config;
    const profile = vm.runInContext(
        'generate(__config.pumpSettings, __config.bgTargets, __config.isf, __config.basals,' +
        ' __config.preferences, __config.carbRatio, [], __config.model, false, __config.trio)',
        sandbox
    );
    assert.ok(profile && !profile.error, 'profile generation failed: ' + JSON.stringify(profile));
    return profile;
}

function determine(inputs) {
    const { sandbox, logs } = newContext();
    load(sandbox, 'prepare/log.js');
    load(sandbox, 'prepare/determine-basal.js');
    load(sandbox, 'bundle/basal-set-temp.js');
    load(sandbox, 'bundle/glucose-get-last.js');
    load(sandbox, 'bundle/determine-basal.js');
    vm.runInContext('function middleware() { return "Nothing changed"; }', sandbox);
    sandbox.__in = inputs;
    const result = vm.runInContext(
        'generate(__in.iob, __in.currentTemp, __in.glucose, __in.profile, __in.autosens, __in.meal,' +
        ' true, null, new Date(), [], __in.preferences, __in.basals, __in.trio)',
        sandbox
    );
    assert.ok(result && !result.error, 'determination failed: ' + JSON.stringify(result));
    return { result, logs };
}

// --- scenario construction ------------------------------------------------

// `scale` is the pumped-volume multiplier: 1 for U-100, 10 for U-10, and so on.
// Real therapy is identical across scales by construction.
function build(therapy, scale, glucoseSeries) {
    const basals = [{ start: '00:00:00', minutes: 0, rate: therapy.basal * scale, i: 0 }];
    const preferences = {
        max_iob: therapy.maxIOB * scale,
        max_daily_safety_multiplier: 3, current_basal_safety_multiplier: 4,
        autosens_max: 1.2, autosens_min: 0.7, smb_delivery_ratio: 0.5,
        maxCOB: 120, maxMealAbsorptionTime: 6, min_5m_carbimpact: 8,
        remainingCarbsCap: 90, remainingCarbsFraction: 1,
        enableUAM: true, enableSMB_always: true, enableSMB_with_COB: true,
        enableSMB_with_temptarget: true, enableSMB_after_carbs: true,
        allowSMB_with_high_temptarget: false, A52_risk_enable: false,
        maxSMBBasalMinutes: therapy.smbMinutes, maxUAMSMBBasalMinutes: therapy.smbMinutes,
        SMBInterval: 3,
        // The bolus increment is a property of the PUMP, not of the insulin, so
        // it is deliberately NOT scaled: the pump meters the same 0.05 U of
        // fluid whatever the fluid contains. This is the one quantity that is
        // legitimately not scale-invariant, and the reason dilution improves
        // dosing resolution at all.
        bolus_increment: 0.05,
        curve: 'rapid-acting', useCustomPeakTime: false, insulinPeakTime: 75,
        maxDelta_bg_threshold: 0.2, adjustmentFactor: 0.8, adjustmentFactorSigmoid: 0.5,
        sigmoid: false, useNewFormula: therapy.dynamicISF === true, useWeightedAverage: false,
        weightPercentage: 0.35, tddAdjBasal: false, threshold_setting: 60,
        skip_neutral_temps: false, suspend_zeros_iob: true, noisyCGMTargetMultiplier: 1.3,
        carbsReqThreshold: 1, high_temptarget_raises_sensitivity: false,
        low_temptarget_lowers_sensitivity: false, sensitivity_raises_target: false,
        resistance_lowers_target: false, adv_target_adjustments: false, exercise_mode: false,
        half_basal_exercise_target: 160, wide_bg_target_range: false, unsuspend_if_no_temp: false,
        rewind_resets_autosens: true, enableSMB_high_bg: false, enableSMB_high_bg_target: 110,
        updateInterval: 20
    };
    const tddFields = {
        currentTDD: therapy.tdd * scale, weightedAverage: therapy.tdd * scale,
        past2hoursAverage: therapy.tdd * scale, average_total_data: therapy.tdd * scale
    };
    const profile = makeProfile({
        pumpSettings: {
            insulin_action_curve: 6,
            maxBolus: therapy.maxBolus * scale,
            maxBasal: therapy.maxBasal * scale
        },
        bgTargets: {
            units: 'mg/dL', user_preferred_units: 'mg/dL',
            targets: [{ low: 100, high: 100, start: '00:00:00', offset: 0 }]
        },
        // ISF and CR are per-unit, so they move the OTHER way.
        isf: {
            units: 'mg/dL', user_preferred_units: 'mg/dL',
            sensitivities: [{ sensitivity: therapy.isf / scale, offset: 0, start: '00:00:00' }]
        },
        carbRatio: {
            units: 'grams',
            schedule: [{ start: '00:00:00', offset: 0, ratio: therapy.carbRatio / scale }]
        },
        basals, preferences, model: '"523"',
        trio: Object.assign({
            onlyAutotuneBasals: false, useNewFormula: therapy.dynamicISF === true,
            sigmoid: false, weigthPercentage: 0.35,
            adjustmentFactor: 0.8, adjustmentFactorSigmoid: 0.5, date: 0
        }, tddFields)
    });

    const now = Date.now();
    const glucose = glucoseSeries.map((sgv, index) => ({
        date: now - index * 5 * 60000,
        dateString: new Date(now - index * 5 * 60000).toISOString(),
        sgv, glucose: sgv, type: 'sgv', device: 'sim'
    }));

    // oref reads iob_data as an array of per-5-minute predictions.
    const iob = Array.from({ length: 48 }, (_, step) => {
        const decay = Math.max(0, 1 - step / 48);
        return {
            iob: therapy.iob * scale * decay,
            activity: therapy.activity * scale * decay,
            basaliob: therapy.iob * scale * decay * 0.3,
            bolusiob: therapy.iob * scale * decay * 0.7,
            netbasalinsulin: therapy.iob * scale * 0.3,
            bolusinsulin: therapy.iob * scale * 0.7,
            iobWithZeroTemp: { iob: therapy.iob * scale * decay, activity: therapy.activity * scale * decay },
            lastBolusTime: now - 120 * 60000,
            lastTemp: {
                rate: therapy.basal * scale,
                timestamp: new Date(now - 60 * 60000).toISOString(),
                started_at: new Date(now - 60 * 60000).toISOString(),
                date: now - 60 * 60000, duration: 0
            },
            time: new Date(now + step * 5 * 60000).toISOString()
        };
    });

    return {
        profile, glucose, iob, preferences, basals,
        currentTemp: { duration: 0, rate: 0, temp: 'absolute' },
        autosens: { ratio: 1 },
        meal: {
            carbs: therapy.cob || 0, nsCarbs: therapy.cob || 0, bwCarbs: 0, journalCarbs: 0,
            mealCOB: therapy.cob || 0, currentDeviation: 3, maxDeviation: 5, minDeviation: 1,
            slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0, allDeviations: [3, 3, 3],
            lastCarbTime: therapy.cob ? now - 20 * 60000 : 0, bwFound: false
        },
        trio: Object.assign({
            useOverride: false, overridePercentage: 100, smbIsOff: false, smbIsScheduledOff: false,
            advancedSettings: false, isfAndCr: false, isf: false, cr: false,
            smbMinutes: therapy.smbMinutes, uamMinutes: therapy.smbMinutes,
            overrideTarget: 0, duration: 0, useNewFormula: therapy.dynamicISF === true,
            sigmoid: false, adjustmentFactor: 0.8, adjustmentFactorSigmoid: 0.5,
            weigthPercentage: 0.35, enableSMB_high_bg: false, enableSMB_high_bg_target: 110
        }, tddFields)
    };
}

// Tolerances, in units of ACTUAL insulin, for comparing a diluted run against
// the undiluted one. Invariance is exact in the algebra but not in the output:
// oref quantises its results, and every quantum is denominated in PUMPED units
// — the pump's bolus increment, its basal increment, and oref's own rounding of
// insulinReq to two decimals. Diluting shrinks all of them in real terms, so the
// diluted answer is the more precise of the two, and can differ from the
// undiluted one by up to one undiluted quantum. That is the correct invariant to
// pin: agreement to within the coarseness the U-100 run itself has.
const REAL_TOLERANCE = {
    units: 0.05, // pump bolus increment
    rate: 0.05, // pump basal increment
    insulinReq: 0.01, // round(insulinReq, 2)
    insulinForManualBolus: 0.01,
    IOB: 0.01
};

/// Asserts that every insulin-denominated output at `scale`, converted back to
/// actual insulin, matches the undiluted output to within the undiluted run's
/// own granularity — and that diluting never delivers LESS. Glucose-denominated
/// outputs must be bit-identical.
function assertScaleInvariant(label, therapy, glucoseSeries, scale) {
    const plain = determine(build(therapy, 1, glucoseSeries)).result;
    const diluted = determine(build(therapy, scale, glucoseSeries)).result;

    for (const field of Object.keys(REAL_TOLERANCE)) {
        // An absent SMB means "nothing deliverable this cycle" — 0 U of insulin,
        // which is exactly what it should be compared as.
        const a = plain[field] === undefined ? 0 : plain[field];
        const b = (diluted[field] === undefined ? 0 : diluted[field]) / scale;
        const tolerance = REAL_TOLERANCE[field];
        checks += 1;
        assert.ok(
            Math.abs(b - a) <= tolerance + 1e-9,
            label + ' x' + scale + ': ' + field + ' is ' + b + ' U of actual insulin, undiluted gives ' +
            a + ' (differs by more than the undiluted granularity of ' + tolerance + ')'
        );
    }

    // Dilution must never cost insulin: finer increments can only round a dose
    // up towards what the algorithm asked for, never away from it.
    const plainSMB = plain.units === undefined ? 0 : plain.units;
    const dilutedSMB = (diluted.units === undefined ? 0 : diluted.units) / scale;
    checks += 1;
    assert.ok(
        dilutedSMB >= plainSMB - 1e-9,
        label + ' x' + scale + ': SMB fell from ' + plainSMB + ' U to ' + dilutedSMB + ' U of actual insulin'
    );

    // Glucose predictions describe the patient, not the fluid: identical.
    for (const field of ['eventualBG', 'bg', 'threshold', 'target_bg']) {
        checks += 1;
        assert.strictEqual(
            diluted[field], plain[field],
            label + ': ' + field + ' must not change with concentration'
        );
    }
}

// --- scenarios ------------------------------------------------------------

const RAPID_RISE = [195, 180, 165, 150, 135];
const FLAT = [120, 120, 119, 120, 121];

// An ordinary adult regimen. Nothing here is near any threshold; this is the
// baseline that proves the comparison itself is sound.
const ADULT = {
    basal: 0.5, isf: 100, carbRatio: 12, maxIOB: 4, maxBolus: 10, maxBasal: 3,
    smbMinutes: 30, tdd: 30, iob: 0.3, activity: 0.005
};

// The regimen dilution exists for: a real basal of 0.05 U/hr, ISF 500, CR 100.
// This is the case the 0.1 U rounding of the SMB cap used to break.
const SMALL_DOSE = {
    basal: 0.05, isf: 500, carbRatio: 100, maxIOB: 1, maxBolus: 1, maxBasal: 0.3,
    smbMinutes: 30, tdd: 3, iob: 0.03, activity: 0.0005
};

console.log('dilution scale invariance');

for (const [name, therapy] of [['adult', ADULT], ['small-dose', SMALL_DOSE]]) {
    for (const scale of [2, 5, 10]) {
        scenario(name + ' / rapid rise / x' + scale, () => {
            assertScaleInvariant(name, therapy, RAPID_RISE, scale);
        });
        scenario(name + ' / flat / x' + scale, () => {
            assertScaleInvariant(name, therapy, FLAT, scale);
        });
    }
    scenario(name + ' / rapid rise with COB / x10', () => {
        assertScaleInvariant(name, Object.assign({}, therapy, { cob: 30 }), RAPID_RISE, 10);
    });
    scenario(name + ' / dynamic ISF / x10', () => {
        assertScaleInvariant(name, Object.assign({}, therapy, { dynamicISF: true }), RAPID_RISE, 10);
    });
}

// The SMB size cap must be exactly maxSMBBasalMinutes worth of basal — never
// rounded up past the user's setting, and never floored to zero for a small
// basal rate, which silently disabled SMBs entirely.
scenario('SMB cap is exactly maxSMBBasalMinutes of basal, at every scale', () => {
    for (const [therapy, scale] of [[ADULT, 1], [ADULT, 10], [SMALL_DOSE, 1], [SMALL_DOSE, 10]]) {
        const { logs } = determine(build(therapy, scale, RAPID_RISE));
        const line = logs.find((l) => l.indexOf('maxBolus: ') >= 0);
        assert.ok(line, 'no maxBolus log line');
        const reported = parseFloat(line.split('maxBolus: ')[1]);
        const expected = therapy.basal * scale * therapy.smbMinutes / 60;
        checks += 1;
        assert.ok(
            Math.abs(reported - expected) <= 0.0005,
            'SMB cap ' + reported + ' != ' + expected + ' (basal ' + therapy.basal +
            ' x' + scale + ', ' + therapy.smbMinutes + 'm)'
        );
    }
});

// Diluting must never make a small-dose regimen dose LESS than undiluted. It is
// the whole point: the pump's increment carries proportionally less insulin, so
// doses that round away to nothing at U-100 become deliverable.
scenario('dilution does not reduce deliverable SMB for small-dose therapy', () => {
    const plain = determine(build(SMALL_DOSE, 1, RAPID_RISE)).result;
    const diluted = determine(build(SMALL_DOSE, 10, RAPID_RISE)).result;
    const plainReal = (plain.units || 0);
    const dilutedReal = (diluted.units || 0) / 10;
    checks += 1;
    assert.ok(
        dilutedReal >= plainReal,
        'U-10 delivers ' + dilutedReal + ' U of actual insulin vs ' + plainReal + ' undiluted'
    );
});

// Stored ISF and CR shrink by the factor, and oref's sanity floors are absolute.
// A legitimate diluted profile must still generate — this is the defect that
// returned -1 from profile generation and stopped the loop completely.
scenario('diluted ISF and CR still pass profile sanity floors at U-10', () => {
    const profile = build(SMALL_DOSE, 10, RAPID_RISE).profile;
    checks += 1;
    assert.strictEqual(profile.sens, SMALL_DOSE.isf / 10, 'ISF rejected or altered');
    assert.strictEqual(profile.carb_ratio, SMALL_DOSE.carbRatio / 10, 'carb ratio rejected or altered');
});

console.log(failures === 0
    ? '\nall scenarios passed (' + checks + ' assertions)'
    : '\n' + failures + ' scenario(s) failed');
process.exit(failures === 0 ? 0 : 1);
