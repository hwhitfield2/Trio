
var getTime = require('../medtronic-clock');

function carbRatioLookup (inputs, profile, now) {
    if (typeof(now) === 'undefined') {
        now = new Date();
    }
    var carbratio_data = inputs.carbratio;
    if (typeof(carbratio_data) !== "undefined" && typeof(carbratio_data.schedule) !== "undefined") {
        var carbRatio;
        if ((carbratio_data.units === "grams") || (carbratio_data.units === "exchanges")) {
            //carbratio_data.schedule.sort(function (a, b) { return a.offset > b.offset });
            carbRatio = carbratio_data.schedule[carbratio_data.schedule.length - 1];

            for (var i = 0; i < carbratio_data.schedule.length - 1; i++) {
                if ((now >= getTime(carbratio_data.schedule[i].offset)) && (now < getTime(carbratio_data.schedule[i + 1].offset))) {
                    carbRatio = carbratio_data.schedule[i];
                    break;
                }
            }
            // disallow impossibly high/low carbRatios due to bad decoding.
            // Upper bound raised from 150 to 500 g/U to support very-low-dose
            // therapy regimens (a 500:1 ratio with ISF up to 1800 mg/dL/U);
            // a ratio above bounds previously made carb_ratio undefined,
            // which surfaced as CR: NaN and silently broke all COB math.
            // Lower bound lowered from 1 to 0.1: ratio is g per PUMPED unit;
            // with U-10 dilution real CR is stored /10, so the CR editor real
            // minimum of 1 g/U becomes 0.1 stored at U-10.
            if (carbRatio.ratio < 0.1 || carbRatio.ratio > 500) {
                console.error("Error: carbRatio of " + carbRatio.ratio + " out of bounds.");
                return;
            }

            if (carbratio_data.units === "exchanges") {
                carbRatio.ratio = 12 / carbRatio.ratio
            }
            return carbRatio.ratio;
        } else {
            console.error("Error: Unsupported carb_ratio units " + carbratio_data.units);
            return;
        }
    //return carbRatio.ratio;
    //profile.carbratio = carbRatio.ratio;
    } else { return; }
}

carbRatioLookup.carbRatioLookup = carbRatioLookup;
exports = module.exports = carbRatioLookup;
