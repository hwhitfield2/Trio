//для monitor/meal.json параметры: monitor/pumphistory-24h-zoned.json settings/profile.json monitor/clock-zoned.json monitor/glucose.json settings/basal_profile.json monitor/carbhistory.json

function generate(pumphistory_data, profile_data, clock_data, glucose_data, basalprofile_data, carbhistory = false) {
    // carb_ratio is g per PUMPED unit; the floor must sit below the CR editor
    // real minimum of 1 g/U at U-5 dilution (stores 1/20 = 0.05).
    if (typeof(profile_data.carb_ratio) === 'undefined' || profile_data.carb_ratio < 0.04) {
        return {"error":"Error: carb_ratio " + profile_data.carb_ratio + " out of bounds"};
    }

    var carb_data = { };
    if (carbhistory) {
        carb_data = carbhistory;
    }

    if (typeof basalprofile_data[0] === 'undefined') {
        return { "error":"Error: bad basalprofile_data: " + JSON.stringify(basalprofile_data) };
    }

    var inputs = {
      history: pumphistory_data
    , profile: profile_data
    , basalprofile: basalprofile_data
    , clock: clock_data
    , carbs: carb_data
    , glucose: glucose_data
    };

    var recentCarbs = trio_meal(inputs);

    if (glucose_data.length < 4) {
        console.error("Not enough glucose data to calculate carb absorption; found:", glucose_data.length);
        recentCarbs.mealCOB = 0;
        recentCarbs.reason = "not enough glucose data to calculate carb absorption";
    }

    return recentCarbs;
}
