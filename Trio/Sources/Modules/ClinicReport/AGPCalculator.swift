import Foundation

/// A minimal, thread-safe glucose reading used by the AGP report calculator.
struct GlucoseReadingLite: Equatable, Sendable {
    /// Timestamp of the reading.
    let date: Date
    /// Glucose value in mg/dL.
    let glucose: Int
}

/// Percentile statistics for one half-hour time-of-day bin (0-47).
struct AGPTimeBinStats: Equatable, Sendable {
    /// Half-hour bin index: 0 = 00:00-00:29, 47 = 23:30-23:59.
    let binIndex: Int
    let p5: Double
    let p25: Double
    let p50: Double
    let p75: Double
    let p95: Double
}

/// One calendar day of readings, used for the daily thumbnail charts.
struct AGPDailySeries: Equatable, Sendable {
    /// Start of the calendar day.
    let date: Date
    /// Readings of that day, sorted ascending by date.
    let readings: [GlucoseReadingLite]
}

/// Standardized AGP time-in-range bands, each as percent of all readings.
/// These use the fixed international consensus thresholds, NOT the user's
/// personal targets — AGP reports are standardized so clinicians can compare.
struct AGPTimeInRanges: Equatable, Sendable {
    /// < 54 mg/dL
    let veryLowPercent: Double
    /// 54-69 mg/dL
    let lowPercent: Double
    /// 70-180 mg/dL
    let inRangePercent: Double
    /// 181-250 mg/dL
    let highPercent: Double
    /// > 250 mg/dL
    let veryHighPercent: Double

    static let zero = AGPTimeInRanges(
        veryLowPercent: 0,
        lowPercent: 0,
        inRangePercent: 0,
        highPercent: 0,
        veryHighPercent: 0
    )
}

/// All derived data needed to draw the on-screen preview and the PDF report.
/// Every glucose value is in mg/dL; conversion happens at display time only.
struct AGPReportData: Equatable, Sendable {
    let periodStart: Date
    let periodEnd: Date
    let periodDays: Int
    let readingsCount: Int
    /// Percentage of expected CGM readings actually present (5-minute cadence), capped at 100.
    let cgmActivePercent: Double
    /// Mean glucose in mg/dL (0 when there are no readings).
    let meanGlucose: Double
    /// Glucose Management Indicator in % (0 when there are no readings).
    let gmiPercent: Double
    /// Coefficient of variation in % (sample SD / mean x 100).
    let cvPercent: Double
    /// True when CV >= 36 %, the consensus "high variability" threshold.
    let isHighVariability: Bool
    let timeInRanges: AGPTimeInRanges
    /// 48 half-hour time-of-day bins; `nil` where a bin has no readings.
    let timeBins: [AGPTimeBinStats?]
    /// Per-day reading series for the daily thumbnails, ascending by day.
    let dailySeries: [AGPDailySeries]
    /// Mean of the per-day TDD means, if TDD data was provided.
    let averageTDD: Double?
    /// Mean of the per-day carb totals, if carb data was provided.
    let averageDailyCarbs: Double?
}

/// Pure value-type AGP statistics calculator. No DI, no Core Data — unit-testable.
enum AGPCalculator {
    /// Expected CGM readings per day at the standard 5-minute cadence.
    static let expectedReadingsPerDay = 288.0

    /// Standard AGP band thresholds in mg/dL.
    static let veryLowThreshold = 54
    static let lowThreshold = 70
    static let highThreshold = 180
    static let veryHighThreshold = 250

    /// CV at or above this value counts as high glucose variability.
    static let highVariabilityCV = 36.0

    static let binsPerDay = 48

    static func calculate(
        readings: [GlucoseReadingLite],
        periodDays: Int,
        endDate: Date = Date(),
        dailyTDDMeans: [Double] = [],
        dailyCarbTotals: [Double] = [],
        calendar: Calendar = .current
    ) -> AGPReportData {
        let clampedDays = max(1, periodDays)
        let periodStart = endDate.addingTimeInterval(-Double(clampedDays) * 24 * 60 * 60)

        let sortedReadings = readings.sorted { $0.date < $1.date }
        let values = sortedReadings.map { Double($0.glucose) }
        let count = values.count

        let expectedReadings = Double(clampedDays) * expectedReadingsPerDay
        let cgmActivePercent = count > 0 ? min(Double(count) / expectedReadings * 100, 100) : 0

        let mean = count > 0 ? values.reduce(0, +) / Double(count) : 0
        let gmiPercent = count > 0 ? 3.31 + 0.02392 * mean : 0

        var cvPercent = 0.0
        if count > 1, mean > 0 {
            let variance = values.reduce(0.0) { $0 + ($1 - mean) * ($1 - mean) } / Double(count - 1)
            cvPercent = variance.squareRoot() / mean * 100
        }

        let averageTDD = dailyTDDMeans.isEmpty ? nil : dailyTDDMeans.reduce(0, +) / Double(dailyTDDMeans.count)
        let averageDailyCarbs = dailyCarbTotals.isEmpty ? nil : dailyCarbTotals
            .reduce(0, +) / Double(dailyCarbTotals.count)

        return AGPReportData(
            periodStart: periodStart,
            periodEnd: endDate,
            periodDays: clampedDays,
            readingsCount: count,
            cgmActivePercent: cgmActivePercent,
            meanGlucose: mean,
            gmiPercent: gmiPercent,
            cvPercent: cvPercent,
            isHighVariability: cvPercent >= highVariabilityCV,
            timeInRanges: timeInRanges(of: sortedReadings),
            timeBins: timeBins(of: sortedReadings, calendar: calendar),
            dailySeries: dailySeries(of: sortedReadings, calendar: calendar),
            averageTDD: averageTDD,
            averageDailyCarbs: averageDailyCarbs
        )
    }

    /// Percentage of readings in each standard AGP band.
    static func timeInRanges(of readings: [GlucoseReadingLite]) -> AGPTimeInRanges {
        guard !readings.isEmpty else { return .zero }
        let total = Double(readings.count)
        let veryLow = readings.filter { $0.glucose < veryLowThreshold }.count
        let low = readings.filter { $0.glucose >= veryLowThreshold && $0.glucose < lowThreshold }.count
        let inRange = readings.filter { $0.glucose >= lowThreshold && $0.glucose <= highThreshold }.count
        let high = readings.filter { $0.glucose > highThreshold && $0.glucose <= veryHighThreshold }.count
        let veryHigh = readings.filter { $0.glucose > veryHighThreshold }.count
        return AGPTimeInRanges(
            veryLowPercent: Double(veryLow) / total * 100,
            lowPercent: Double(low) / total * 100,
            inRangePercent: Double(inRange) / total * 100,
            highPercent: Double(high) / total * 100,
            veryHighPercent: Double(veryHigh) / total * 100
        )
    }

    /// 48 half-hour time-of-day bins with interpolated percentiles; `nil` for empty bins.
    static func timeBins(of readings: [GlucoseReadingLite], calendar: Calendar = .current) -> [AGPTimeBinStats?] {
        var grouped: [Int: [Double]] = [:]
        for reading in readings {
            let components = calendar.dateComponents([.hour, .minute], from: reading.date)
            let bin = (components.hour ?? 0) * 2 + ((components.minute ?? 0) >= 30 ? 1 : 0)
            grouped[bin, default: []].append(Double(reading.glucose))
        }
        return (0 ..< binsPerDay).map { bin in
            guard let binValues = grouped[bin]?.sorted(), !binValues.isEmpty else { return nil }
            return AGPTimeBinStats(
                binIndex: bin,
                p5: percentile(0.05, of: binValues),
                p25: percentile(0.25, of: binValues),
                p50: percentile(0.50, of: binValues),
                p75: percentile(0.75, of: binValues),
                p95: percentile(0.95, of: binValues)
            )
        }
    }

    /// Interpolated percentile over pre-sorted values (0 for an empty array).
    static func percentile(_ p: Double, of sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let position = Double(sortedValues.count - 1) * p
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper {
            return sortedValues[lower]
        }
        let weight = position - Double(lower)
        return sortedValues[lower] * (1 - weight) + sortedValues[upper] * weight
    }

    /// Groups readings by calendar day, ascending.
    static func dailySeries(of readings: [GlucoseReadingLite], calendar: Calendar = .current) -> [AGPDailySeries] {
        let grouped = Dictionary(grouping: readings) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            AGPDailySeries(date: day, readings: (grouped[day] ?? []).sorted { $0.date < $1.date })
        }
    }

    /// Per-calendar-day means of sampled values (e.g. rolling-24h TDD samples), ascending by day.
    static func dailyMeans(of samples: [(date: Date, value: Double)], calendar: Calendar = .current) -> [Double] {
        let grouped = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().compactMap { day in
            guard let dayValues = grouped[day], !dayValues.isEmpty else { return nil }
            return dayValues.reduce(0.0) { $0 + $1.value } / Double(dayValues.count)
        }
    }

    /// Per-calendar-day totals of sampled values (e.g. carb entries), ascending by day.
    static func dailyTotals(of samples: [(date: Date, value: Double)], calendar: Calendar = .current) -> [Double] {
        let grouped = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted().map { day in
            (grouped[day] ?? []).reduce(0.0) { $0 + $1.value }
        }
    }
}
