import Foundation
import Testing

@testable import Trio

@Suite("AGP Calculator Tests") struct AGPCalculatorTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(day: Int, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 6, day: day, hour: hour, minute: minute))!
    }

    /// Builds `days` full days of readings at a 5-minute cadence, ending 2025-06-15 00:00 UTC.
    private func makeReadings(days: Int, glucose: (Int) -> Int) -> (readings: [GlucoseReadingLite], endDate: Date) {
        let endDate = date(day: 15, hour: 0, minute: 0)
        let perDay = 288
        var readings: [GlucoseReadingLite] = []
        for index in 0 ..< (days * perDay) {
            let readingDate = endDate.addingTimeInterval(-Double(index + 1) * 300)
            readings.append(GlucoseReadingLite(date: readingDate, glucose: glucose(index)))
        }
        return (readings, endDate)
    }

    @Test("Constant 100 mg/dL gives known mean, GMI, CV and 100 % in range") func testConstantGlucose() {
        let (readings, endDate) = makeReadings(days: 14) { _ in 100 }
        let data = AGPCalculator.calculate(readings: readings, periodDays: 14, endDate: endDate, calendar: calendar)

        #expect(data.readingsCount == 14 * 288)
        #expect(data.cgmActivePercent == 100)
        #expect(abs(data.meanGlucose - 100) < 0.0001)
        #expect(abs(data.gmiPercent - (3.31 + 0.02392 * 100)) < 0.0001)
        #expect(data.cvPercent == 0)
        #expect(!data.isHighVariability)
        #expect(abs(data.timeInRanges.inRangePercent - 100) < 0.0001)
        #expect(data.timeInRanges.veryLowPercent == 0)
        #expect(data.timeInRanges.lowPercent == 0)
        #expect(data.timeInRanges.highPercent == 0)
        #expect(data.timeInRanges.veryHighPercent == 0)
        #expect(data.dailySeries.count == 14)
    }

    @Test("Alternating 60/200 splits into low and high bands and flags high variability") func testAlternatingGlucose() {
        let (readings, endDate) = makeReadings(days: 14) { index in index.isMultiple(of: 2) ? 60 : 200 }
        let data = AGPCalculator.calculate(readings: readings, periodDays: 14, endDate: endDate, calendar: calendar)

        #expect(abs(data.meanGlucose - 130) < 0.0001)
        #expect(abs(data.timeInRanges.lowPercent - 50) < 0.0001)
        #expect(abs(data.timeInRanges.highPercent - 50) < 0.0001)
        #expect(data.timeInRanges.inRangePercent == 0)
        #expect(data.timeInRanges.veryLowPercent == 0)
        #expect(data.timeInRanges.veryHighPercent == 0)
        // SD is ~70, mean 130 -> CV ~53.8 %, well above the 36 % threshold.
        #expect(data.cvPercent > 50)
        #expect(data.isHighVariability)
    }

    @Test("Empty input yields zeroed report with all bins empty") func testEmptyInput() {
        let data = AGPCalculator.calculate(readings: [], periodDays: 14, calendar: calendar)

        #expect(data.readingsCount == 0)
        #expect(data.cgmActivePercent == 0)
        #expect(data.meanGlucose == 0)
        #expect(data.gmiPercent == 0)
        #expect(data.cvPercent == 0)
        #expect(!data.isHighVariability)
        #expect(data.timeInRanges == .zero)
        #expect(data.timeBins.count == 48)
        #expect(data.timeBins.allSatisfy { $0 == nil })
        #expect(data.dailySeries.isEmpty)
        #expect(data.averageTDD == nil)
        #expect(data.averageDailyCarbs == nil)
    }

    @Test("Single day of data produces one daily series") func testSingleDay() {
        let (readings, endDate) = makeReadings(days: 1) { _ in 120 }
        let data = AGPCalculator.calculate(readings: readings, periodDays: 14, endDate: endDate, calendar: calendar)

        // 288 of 14 x 288 expected readings.
        #expect(abs(data.cgmActivePercent - 100.0 / 14.0) < 0.01)
        #expect(data.dailySeries.count == 1)
        #expect(data.dailySeries[0].readings.count == 288)
    }

    @Test("CGM active percentage is capped at 100") func testCGMActiveCap() {
        let (readings, endDate) = makeReadings(days: 2) { _ in 100 }
        let data = AGPCalculator.calculate(readings: readings, periodDays: 1, endDate: endDate, calendar: calendar)
        #expect(data.cgmActivePercent == 100)
    }

    @Test("Band edges land in the standard AGP bands") func testBandEdges() {
        let readings = [53, 54, 69, 70, 180, 181, 250, 251].enumerated().map { offset, glucose in
            GlucoseReadingLite(date: date(day: 1, hour: 12, minute: 0).addingTimeInterval(Double(offset) * 300), glucose: glucose)
        }
        let ranges = AGPCalculator.timeInRanges(of: readings)
        let total = 8.0
        #expect(abs(ranges.veryLowPercent - 1 / total * 100) < 0.0001) // 53
        #expect(abs(ranges.lowPercent - 2 / total * 100) < 0.0001) // 54, 69
        #expect(abs(ranges.inRangePercent - 2 / total * 100) < 0.0001) // 70, 180
        #expect(abs(ranges.highPercent - 2 / total * 100) < 0.0001) // 181, 250
        #expect(abs(ranges.veryHighPercent - 1 / total * 100) < 0.0001) // 251
    }

    @Test("Interpolated percentile matches hand-computed values") func testPercentileInterpolation() {
        #expect(AGPCalculator.percentile(0.5, of: [1, 2, 3, 4]) == 2.5)
        #expect(AGPCalculator.percentile(0.25, of: [0, 10, 20, 30, 40]) == 10)
        #expect(AGPCalculator.percentile(0.5, of: [1, 2, 3]) == 2)
        #expect(AGPCalculator.percentile(0.95, of: [10]) == 10)
        #expect(AGPCalculator.percentile(0.5, of: []) == 0)
        // 0.05 into [0, 100]: position 0.05 -> 5.0
        #expect(abs(AGPCalculator.percentile(0.05, of: [0, 100]) - 5) < 0.0001)
    }

    @Test("Half-hour bins group by time of day with correct percentiles") func testTimeBins() {
        // Ten days, one reading each at 08:10 (bin 16), values 100...1000.
        let readings = (1 ... 10).map { day in
            GlucoseReadingLite(date: date(day: day, hour: 8, minute: 10), glucose: day * 100)
        }
        let bins = AGPCalculator.timeBins(of: readings, calendar: calendar)

        #expect(bins.count == 48)
        let bin = bins[16]
        #expect(bin != nil)
        #expect(bin?.binIndex == 16)
        #expect(bin?.p50 == 550) // median of 100...1000
        #expect(abs((bin?.p25 ?? 0) - 325) < 0.0001) // position 2.25 between 300 and 400
        #expect(abs((bin?.p75 ?? 0) - 775) < 0.0001)
        // Every other bin is empty.
        #expect(bins.enumerated().allSatisfy { index, value in index == 16 || value == nil })
    }

    @Test("Readings at 08:40 land in the second half-hour bin") func testHalfHourBinBoundary() {
        let readings = [GlucoseReadingLite(date: date(day: 1, hour: 8, minute: 40), glucose: 100)]
        let bins = AGPCalculator.timeBins(of: readings, calendar: calendar)
        #expect(bins[17] != nil)
        #expect(bins[16] == nil)
    }

    @Test("Daily means and totals aggregate per calendar day") func testDailyMeansAndTotals() {
        let samples: [(date: Date, value: Double)] = [
            (date: date(day: 1, hour: 8, minute: 0), value: 30),
            (date: date(day: 1, hour: 20, minute: 0), value: 50),
            (date: date(day: 2, hour: 12, minute: 0), value: 42)
        ]
        #expect(AGPCalculator.dailyMeans(of: samples, calendar: calendar) == [40, 42])
        #expect(AGPCalculator.dailyTotals(of: samples, calendar: calendar) == [80, 42])
    }

    @Test("TDD daily means and carb totals average into the report summary") func testSummaryAverages() {
        let (readings, endDate) = makeReadings(days: 2) { _ in 100 }
        let data = AGPCalculator.calculate(
            readings: readings,
            periodDays: 2,
            endDate: endDate,
            dailyTDDMeans: [40, 44],
            dailyCarbTotals: [150, 170],
            calendar: calendar
        )
        #expect(data.averageTDD == 42)
        #expect(data.averageDailyCarbs == 160)
    }
}
