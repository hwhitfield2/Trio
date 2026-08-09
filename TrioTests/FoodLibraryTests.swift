import Foundation
import Testing

@testable import Trio

@Suite("Food Library Tests") struct FoodLibraryTests {
    private let mealDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func reading(minutes: Double, glucose: Int) -> FoodGlucoseReading {
        FoodGlucoseReading(date: mealDate.addingTimeInterval(minutes * 60), glucose: glucose)
    }

    // MARK: - Name normalization (the library upsert key)

    @Test("Normalization lowercases and trims whitespace") func testNormalization() {
        #expect(FoodOutcomeMath.normalizedName("  Chicken Burrito  ") == "chicken burrito")
        #expect(FoodOutcomeMath.normalizedName("PIZZA\n") == "pizza")
        #expect(FoodOutcomeMath.normalizedName("   ") == "")
        #expect(FoodOutcomeMath.normalizedName("Käsespätzle") == "käsespätzle")
    }

    // MARK: - Full outcome over a typical post-meal curve

    @Test("Typical rise-and-return curve yields peak, end, and no flags") func testTypicalOutcome() {
        let readings = [
            reading(minutes: -5, glucose: 120),
            reading(minutes: 30, glucose: 150),
            reading(minutes: 60, glucose: 185),
            reading(minutes: 90, glucose: 170),
            reading(minutes: 180, glucose: 140),
            reading(minutes: 235, glucose: 130)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)

        #expect(outcome.hasStartReading)
        #expect(outcome.startGlucose == 120)
        #expect(outcome.peakDelta == 65) // 185 at +60 min minus 120 start
        #expect(outcome.endGlucose == 130) // +235 min is nearest the 4 h mark
        #expect(!outcome.hypoWithin4h)
        #expect(!outcome.endedAboveRange)
    }

    @Test("Start reading is the one nearest the meal time") func testStartSelection() {
        let readings = [
            reading(minutes: -18, glucose: 100),
            reading(minutes: -2, glucose: 110),
            reading(minutes: 15, glucose: 125),
            reading(minutes: 230, glucose: 120)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.startGlucose == 110)
    }

    // MARK: - Degenerate case: no reading near the meal

    @Test("No reading within 20 minutes of the meal yields a zeroed outcome") func testMissingStart() {
        let readings = [
            reading(minutes: -60, glucose: 120),
            reading(minutes: 45, glucose: 200),
            reading(minutes: 120, glucose: 60),
            reading(minutes: 240, glucose: 220)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)

        #expect(!outcome.hasStartReading)
        #expect(outcome.startGlucose == 0)
        #expect(outcome.peakDelta == 0)
        #expect(outcome.endGlucose == 0)
        #expect(!outcome.hypoWithin4h)
        #expect(!outcome.endedAboveRange)
    }

    @Test("No readings at all yields a zeroed outcome") func testNoReadings() {
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: [])
        #expect(!outcome.hasStartReading)
        #expect(outcome.peakDelta == 0)
    }

    // MARK: - Peak window edges

    @Test("Readings after the 2 hour mark do not count toward the peak") func testPeakWindow() {
        let readings = [
            reading(minutes: 0, glucose: 100),
            reading(minutes: 60, glucose: 130),
            reading(minutes: 150, glucose: 250), // outside peak window
            reading(minutes: 235, glucose: 120)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.peakDelta == 30)
    }

    @Test("No readings inside the peak window yields peakDelta 0") func testMissingPeak() {
        let readings = [
            reading(minutes: 0, glucose: 100),
            reading(minutes: 150, glucose: 180),
            reading(minutes: 235, glucose: 150)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.peakDelta == 0)
        #expect(outcome.endGlucose == 150)
    }

    @Test("Peak below the start yields a negative delta") func testNegativePeakDelta() {
        let readings = [
            reading(minutes: 0, glucose: 150),
            reading(minutes: 60, glucose: 130),
            reading(minutes: 235, glucose: 120)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.peakDelta == -20)
    }

    // MARK: - End reading edges

    @Test("No reading within 30 minutes of the 4 hour mark yields endGlucose 0") func testMissingEnd() {
        let readings = [
            reading(minutes: 0, glucose: 100),
            reading(minutes: 60, glucose: 160),
            reading(minutes: 120, glucose: 140)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.endGlucose == 0)
        #expect(!outcome.endedAboveRange)
    }

    @Test("Ending above 180 sets the above-range flag") func testEndedAboveRange() {
        let readings = [
            reading(minutes: 0, glucose: 120),
            reading(minutes: 90, glucose: 220),
            reading(minutes: 230, glucose: 195)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.endGlucose == 195)
        #expect(outcome.endedAboveRange)
    }

    @Test("Ending exactly at 180 does not set the above-range flag") func testEndAtThreshold() {
        let readings = [
            reading(minutes: 0, glucose: 120),
            reading(minutes: 230, glucose: 180)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(!outcome.endedAboveRange)
    }

    // MARK: - Hypo detection

    @Test("Any reading below 70 inside the 4 hour window sets the hypo flag") func testHypoWithin4h() {
        let readings = [
            reading(minutes: 0, glucose: 110),
            reading(minutes: 100, glucose: 65),
            reading(minutes: 230, glucose: 120)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(outcome.hypoWithin4h)
    }

    @Test("A low before the meal does not set the hypo flag") func testHypoBeforeMealIgnored() {
        let readings = [
            reading(minutes: -10, glucose: 65),
            reading(minutes: 0, glucose: 75),
            reading(minutes: 60, glucose: 140),
            reading(minutes: 230, glucose: 120)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(!outcome.hypoWithin4h)
    }

    @Test("A low after the 4 hour window does not set the hypo flag") func testHypoAfterWindowIgnored() {
        let readings = [
            reading(minutes: 0, glucose: 110),
            reading(minutes: 230, glucose: 120),
            reading(minutes: 250, glucose: 60)
        ]
        let outcome = FoodOutcomeMath.outcome(mealDate: mealDate, readings: readings)
        #expect(!outcome.hypoWithin4h)
    }
}
