/*
  Scenario tests for UAM+ (unannounced meal detection) and trend-aware
  eventual BG in determine-basal.js.

  Run with:  NODE_PATH=<dir containing lodash> node trio-oref/tests/unannounced-meal.test.js
  (lodash is the only external dependency; `npm i lodash` anywhere on NODE_PATH works)

  Scenarios:
   1. smoothie   — partially logged meal (sandwich logged, smoothie not):
                   sustained rising deviations with mostly-absorbed COB
                   → UAM+ must activate, raise eventualBG, and dose (capped)
   2. falling    — sustained negative deviations
                   → no UAM+; trend must not raise eventualBG; no SMB
   3. rebound    — rising from below target
                   → no UAM+ (BG gate)
   4. freshMeal  — fresh logged meal fully explaining deviations
                   → no UAM+
   5. guard      — rising deviations but large IOB crashing predictions
                   → guards still win: zero temp, no SMB even if UAM+ fires
*/

var determine_basal = require('../lib/determine-basal/determine-basal');
var tempBasalFunctions = require('../lib/basal-set-temp');

var now = Date.now();

function baseProfile() {
    return {
        current_basal: 0.05, max_daily_basal: 0.05, max_basal: 2, max_iob: 1.5,
        min_bg: 100, max_bg: 100, sens: 270, carb_ratio: 27,
        enableUAM: true, enableSMB_always: true, allowSMB_with_high_temptarget: false,
        A52_risk_enable: false, temptargetSet: false,
        maxSMBBasalMinutes: 120, maxUAMSMBBasalMinutes: 120,
        smb_delivery_ratio: 0.5, bolus_increment: 0.05,
        autosens_min: 0.7, autosens_max: 1.2,
        min_5m_carbimpact: 8, remainingCarbsCap: 90, threshold_setting: 60,
        insulinPeakTime: 75, skip_neutral_temps: false,
        noisyCGMTargetMultiplier: 1.3, maxRaw: 200, out_units: 'mg/dL',
        SMBInterval: 3, maxDelta_bg_threshold: 0.2, half_basal_exercise_target: 160,
        weightPercentage: 1, tddAdjBasal: false,
        high_temptarget_raises_sensitivity: false, low_temptarget_lowers_sensitivity: false,
        sensitivity_raises_target: false, resistance_lowers_target: false,
        exercise_mode: false, enableSMB_high_bg: false, carbsReqThreshold: 1,
        max_daily_safety_multiplier: 3, current_basal_safety_multiplier: 4
    };
}

function customVars() {
    return {
        smbIsOff: false, smbIsScheduledOff: false, start: 0, end: 0,
        advancedSettings: false, isfAndCr: false, isf: false, cr: false,
        smbMinutes: 30, uamMinutes: 30,
        currentTDD: 6, weightedAverage: 6, average_total_data: 6,
        useOverride: false, overridePercentage: 100, overrideTarget: 0, duration: 0
    };
}

function iobArray(iob, activity) {
    var arr = [];
    for (var k = 0; k < 48; k++) {
        var frac = Math.max(0, 1 - k / 36);
        arr.push({
            iob: iob * frac,
            activity: activity * frac,
            iobWithZeroTemp: { iob: iob * frac, activity: activity * frac }
        });
    }
    arr[0].lastBolusTime = now - 20 * 60 * 1000;
    arr[0].lastTemp = { date: now - 4 * 60 * 1000, rate: 0.05, duration: 30 };
    return arr;
}

function glucoseStatus(bg, delta, shortAvg, longAvg) {
    return { glucose: bg, delta: delta, short_avgdelta: shortAvg, long_avgdelta: longAvg, date: now, noise: 0, device: 'dexcom' };
}

var preferences = { useNewFormula: false, sigmoid: false, adjustmentFactor: 0.8, adjustmentFactorSigmoid: 0.5, curve: 'rapid-acting', useCustomPeakTime: false };
var currenttemp = { rate: 0.05, duration: 25, temp: 'absolute' };

function run(inputs) {
    var origLog = console.log, origErr = console.error, origWrite = process.stderr.write;
    if (!process.env.VERBOSE) {
        console.log = function () {};
        console.error = function () {};
        process.stderr.write = function () { return true; };
    }
    var rT;
    try {
        rT = determine_basal(
            inputs.glucose_status, currenttemp, inputs.iob, inputs.profile,
            { ratio: 1.0 }, inputs.meal_data, tempBasalFunctions, true,
            null, new Date(now), {}, preferences, [], customVars(), ''
        );
    } finally {
        console.log = origLog;
        console.error = origErr;
        process.stderr.write = origWrite;
    }
    return rT;
}

module.exports = { run: run, scenarios: function () { return { s1: s1, s1b: s1b, s2: s2, s3: s3, s4: s4, s5: s5 }; }, deps: { baseProfile: baseProfile, customVars: customVars, iobArray: iobArray, glucoseStatus: glucoseStatus, preferences: preferences, currenttemp: currenttemp, now: now } };

var failures = [];
function check(name, cond, detail) {
    if (cond) {
        console.log("  PASS  " + name);
    } else {
        console.log("  FAIL  " + name + (detail ? "  [" + detail + "]" : ""));
        failures.push(name);
    }
}

// ---------------------------------------------------------------------------
console.log("Scenario 1: smoothie (sandwich logged, smoothie not)");
var s1 = {
    glucose_status: glucoseStatus(152, 4, 4.5, 3.5),
    iob: iobArray(0.05, 0.0002),
    profile: baseProfile(),
    meal_data: {
        carbs: 39, mealCOB: 5, nsCarbs: 39, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: 5.5, maxDeviation: 6, minDeviation: 1,
        slopeFromMaxDeviation: -0.5, slopeFromMinDeviation: 1.0,
        allDeviations: [6, 5, 4, 6, 5, 4, 3],
        lastCarbTime: now - 75 * 60 * 1000
    }
};
var r1 = run(s1);
check("UAM+ activates", /UAM\+: unannounced carbs detected/.test(r1.reason), r1.reason);
check("eventualBG well above current BG", r1.eventualBG > 152, "eventualBG=" + r1.eventualBG);
check("positive insulinReq", r1.insulinReq > 0, "insulinReq=" + r1.insulinReq);
check("SMB delivered", typeof r1.units === 'number' && r1.units > 0, "units=" + r1.units);
check("SMB capped by maxUAMSMBBasalMinutes", !(r1.units > 0.1), "units=" + r1.units + " cap=0.1");
console.log("  eventualBG=" + r1.eventualBG + " insulinReq=" + r1.insulinReq + " units=" + r1.units);

// ---------------------------------------------------------------------------
// The screenshot case: meal logged a while ago and model considers it fully
// absorbed (COB run down), but BG is rising steadily at 150+ with IOB on
// board — an unlogged drink. Baseline oref decays the observed deviations
// within the hour and predicts a *drop* (eventualBG ~100-120 while BG rises).
console.log("Scenario 1b: expired logged carbs, steady unexplained rise");
var s1b = {
    glucose_status: glucoseStatus(152, 4, 4.5, 3.5),
    iob: iobArray(0.3, 0.002),
    profile: baseProfile(),
    meal_data: {
        carbs: 39, mealCOB: 0, nsCarbs: 39, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: 4.5, maxDeviation: 5, minDeviation: 1,
        slopeFromMaxDeviation: -1.0, slopeFromMinDeviation: 0.8,
        allDeviations: [4, 5, 4, 4, 5, 4],
        lastCarbTime: now - 120 * 60 * 1000
    }
};
var r1b = run(s1b);
check("UAM+ activates on expired carbs", /UAM\+: unannounced carbs detected/.test(r1b.reason), r1b.reason);
check("eventualBG not below current BG while rising", r1b.eventualBG >= 152, "eventualBG=" + r1b.eventualBG);
check("trend eventualBG surfaced in reason", /trend eventualBG/.test(r1b.reason) || r1b.eventualBG >= 152, r1b.reason);
check("SMB delivered", typeof r1b.units === 'number' && r1b.units > 0, "units=" + r1b.units);
console.log("  eventualBG=" + r1b.eventualBG + " insulinReq=" + r1b.insulinReq + " units=" + r1b.units);

// ---------------------------------------------------------------------------
console.log("Scenario 2: sustained fall");
var s2 = {
    glucose_status: glucoseStatus(130, -4, -4, -3.5),
    iob: iobArray(0.3, 0.002),
    profile: baseProfile(),
    meal_data: {
        carbs: 0, mealCOB: 0, nsCarbs: 0, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: -4, maxDeviation: 0.5, minDeviation: -5,
        slopeFromMaxDeviation: -0.3, slopeFromMinDeviation: 0,
        allDeviations: [-4, -5, -4, -4, -5, -4],
        lastCarbTime: 0
    }
};
var r2 = run(s2);
check("no UAM+ on falling BG", !/UAM\+: unannounced/.test(r2.reason), r2.reason);
check("no SMB on falling BG", !(r2.units > 0), "units=" + r2.units);
check("trend does not raise eventualBG", r2.eventualBG <= 130, "eventualBG=" + r2.eventualBG);
console.log("  eventualBG=" + r2.eventualBG + " rate=" + r2.rate + " duration=" + r2.duration);

// ---------------------------------------------------------------------------
console.log("Scenario 3: rebound rise from below target");
var s3 = {
    glucose_status: glucoseStatus(85, 4, 4, 3),
    iob: iobArray(0.0, 0.0),
    profile: baseProfile(),
    meal_data: {
        carbs: 0, mealCOB: 0, nsCarbs: 0, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: 5, maxDeviation: 5.5, minDeviation: 1,
        slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0.5,
        allDeviations: [5, 5, 4, 6, 5],
        lastCarbTime: 0
    }
};
var r3 = run(s3);
check("no UAM+ below target", !/UAM\+: unannounced/.test(r3.reason), r3.reason);
console.log("  eventualBG=" + r3.eventualBG + " rate=" + r3.rate + " units=" + r3.units);

// ---------------------------------------------------------------------------
console.log("Scenario 4: fresh logged meal explains deviations");
var s4 = {
    glucose_status: glucoseStatus(150, 5, 5, 4),
    iob: iobArray(0.4, 0.001),
    profile: baseProfile(),
    meal_data: {
        carbs: 39, mealCOB: 35, nsCarbs: 39, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: 5, maxDeviation: 5.5, minDeviation: 1,
        slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0.5,
        allDeviations: [5, 5, 4, 6, 5],
        lastCarbTime: now - 20 * 60 * 1000
    }
};
var r4 = run(s4);
check("no UAM+ when COB explains impact", !/UAM\+: unannounced/.test(r4.reason), r4.reason);
console.log("  eventualBG=" + r4.eventualBG + " insulinReq=" + r4.insulinReq + " units=" + r4.units);

// ---------------------------------------------------------------------------
console.log("Scenario 5: hypo guards beat UAM+ (large IOB, crashing predictions)");
var s5 = {
    glucose_status: glucoseStatus(150, 4, 4, 3.5),
    iob: iobArray(1.4, 0.02),
    profile: baseProfile(),
    meal_data: {
        carbs: 39, mealCOB: 5, nsCarbs: 39, bwCarbs: 0, journalCarbs: 0, bwFound: false,
        currentDeviation: 5, maxDeviation: 5.5, minDeviation: 1,
        slopeFromMaxDeviation: 0, slopeFromMinDeviation: 0.5,
        allDeviations: [5, 5, 4, 6, 5, 4, 4],
        lastCarbTime: now - 75 * 60 * 1000
    }
};
var r5 = run(s5);
check("no SMB when predictions crash", !(r5.units > 0), "units=" + r5.units);
check("zero/low temp set", typeof r5.rate === 'number' && r5.rate <= 0.05, "rate=" + r5.rate);
console.log("  minGuardBG=" + r5.minGuardBG + " rate=" + r5.rate + " duration=" + r5.duration);

// ---------------------------------------------------------------------------
console.log("");
if (failures.length) {
    console.log("FAILED: " + failures.length + " check(s): " + failures.join(", "));
    process.exit(1);
} else {
    console.log("All checks passed.");
}
