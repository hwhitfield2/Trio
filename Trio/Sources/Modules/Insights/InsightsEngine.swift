import Foundation

// MARK: - Engine input (lightweight, Sendable mirrors of Core Data rows)

/// A single CGM reading. Glucose is always mg/dL internally.
struct GlucoseSample: Equatable, Sendable {
    let date: Date
    let glucose: Int
}

/// A single non-FPU carb entry.
struct CarbSample: Equatable, Sendable {
    let date: Date
    let carbs: Double
    let note: String?
}

/// A single enacted algorithm determination (temp basal decision).
struct DeterminationSample: Equatable, Sendable {
    let date: Date
    let rate: Double?
    let scheduledBasal: Double?
    let enacted: Bool
}

// MARK: - Configuration

/// Thresholds used by the pattern detectors. All glucose values are mg/dL.
struct InsightsConfig: Sendable {
    var lowThreshold: Int = 70
    var veryLowThreshold: Int = 54
    var highThreshold: Int = 180
    var reboundThreshold: Int = 250
    var postMealRiseThreshold: Int = 72
    var overnightDriftThreshold: Int = 36
    var minOccurrences: Int = 3
    var analysisWindowDays: Int = 30
    /// Formats an mg/dL value (or delta) for display in card text.
    var glucoseFormatter: @Sendable (Int) -> String = { "\($0) mg/dL" }
}

// MARK: - Output

enum InsightSeverity: Int, CaseIterable, Comparable, Sendable {
    case info = 0
    case notable = 1
    case attention = 2

    static func < (lhs: InsightSeverity, rhs: InsightSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var displayName: String {
        switch self {
        case .info: return String(localized: "For Your Information")
        case .notable: return String(localized: "Notable")
        case .attention: return String(localized: "Worth Attention")
        }
    }
}

enum InsightCategory: Int, CaseIterable, Sendable {
    case hypoTiming = 0
    case hypoWeekday = 1
    case mealResponse = 2
    case basalFit = 3
    case overnight = 4
    case rebound = 5
}

struct InsightCard: Identifiable, Equatable, Sendable {
    let id: String
    let severity: InsightSeverity
    let category: InsightCategory
    let headline: String
    let body: String
    let evidenceLine: String
    let sfSymbol: String
}

// MARK: - Engine

/// Pure pattern detectors over historical data. No DI, no Core Data — unit-testable.
/// All advisory wording is deliberately neutral and non-prescriptive.
enum InsightsEngine {
    struct LowEpisode: Equatable, Sendable {
        let start: Date
        let end: Date
        let minGlucose: Int
    }

    static func analyze(
        glucose: [GlucoseSample],
        carbs: [CarbSample],
        determinations: [DeterminationSample],
        config: InsightsConfig,
        calendar: Calendar = .current
    ) -> [InsightCard] {
        let sortedGlucose = glucose.sorted { $0.date < $1.date }
        let episodes = lowEpisodes(in: sortedGlucose, config: config)

        var cards: [InsightCard] = []
        cards += detectTimeOfDayHypoClusters(episodes: episodes, config: config, calendar: calendar)
        cards += detectWeekdayHypoPattern(episodes: episodes, config: config, calendar: calendar)
        cards += detectPostMealSpikes(carbs: carbs, sortedGlucose: sortedGlucose, config: config)
        cards += detectBasalFrictionWindows(determinations: determinations, config: config, calendar: calendar)
        cards += detectOvernightDrift(sortedGlucose: sortedGlucose, config: config, calendar: calendar)
        cards += detectHypoRebound(episodes: episodes, sortedGlucose: sortedGlucose, config: config)

        return cards.sorted { lhs, rhs in
            if lhs.severity != rhs.severity { return lhs.severity > rhs.severity }
            if lhs.category != rhs.category { return lhs.category.rawValue < rhs.category.rawValue }
            return lhs.id < rhs.id
        }
    }

    // MARK: - Episode building

    /// Groups readings below the low threshold into episodes. A gap of more than
    /// 30 minutes between consecutive low readings starts a new episode.
    static func lowEpisodes(in sortedGlucose: [GlucoseSample], config: InsightsConfig) -> [LowEpisode] {
        let lows = sortedGlucose.filter { $0.glucose < config.lowThreshold }
        guard let first = lows.first else { return [] }

        var episodes: [LowEpisode] = []
        var start = first.date
        var end = first.date
        var minGlucose = first.glucose

        for sample in lows.dropFirst() {
            if sample.date.timeIntervalSince(end) > 30 * 60 {
                episodes.append(LowEpisode(start: start, end: end, minGlucose: minGlucose))
                start = sample.date
                minGlucose = sample.glucose
            } else {
                minGlucose = min(minGlucose, sample.glucose)
            }
            end = sample.date
        }
        episodes.append(LowEpisode(start: start, end: end, minGlucose: minGlucose))
        return episodes
    }

    // MARK: - Detector 1: time-of-day hypo clustering

    static func detectTimeOfDayHypoClusters(
        episodes: [LowEpisode],
        config: InsightsConfig,
        calendar: Calendar
    ) -> [InsightCard] {
        guard episodes.count >= config.minOccurrences else { return [] }

        var blockCounts = [Int](repeating: 0, count: 8)
        for episode in episodes {
            let block = calendar.component(.hour, from: episode.start) / 3
            blockCounts[min(block, 7)] += 1
        }
        let meanPerBlock = Double(episodes.count) / 8.0

        var cards: [InsightCard] = []
        for (block, count) in blockCounts.enumerated()
            where count >= config.minOccurrences && Double(count) >= 2 * meanPerBlock
        {
            let label = hourRangeLabel(from: block * 3, toExclusive: block * 3 + 3)
            let threshold = config.glucoseFormatter(config.lowThreshold)
            cards.append(InsightCard(
                id: "hypo-time-\(block)",
                severity: .attention,
                category: .hypoTiming,
                headline: String(localized: "Lows cluster between \(label)"),
                body: String(
                    localized: "Low glucose episodes (below \(threshold)) have started between \(label) more often than at other times of day. Consider reviewing what typically happens in this window with your care team."
                ),
                evidenceLine: evidenceLine(count: count, days: config.analysisWindowDays),
                sfSymbol: "clock.badge.exclamationmark"
            ))
        }
        return cards
    }

    // MARK: - Detector 2: weekday hypo pattern

    static func detectWeekdayHypoPattern(
        episodes: [LowEpisode],
        config: InsightsConfig,
        calendar: Calendar
    ) -> [InsightCard] {
        guard episodes.count >= config.minOccurrences else { return [] }

        var weekdayCounts = [Int](repeating: 0, count: 7)
        for episode in episodes {
            let weekday = calendar.component(.weekday, from: episode.start) - 1
            weekdayCounts[min(max(weekday, 0), 6)] += 1
        }
        let meanPerWeekday = Double(episodes.count) / 7.0

        var cards: [InsightCard] = []
        for (index, count) in weekdayCounts.enumerated()
            where count >= config.minOccurrences && Double(count) >= 2 * meanPerWeekday
        {
            let dayName = calendar.weekdaySymbols[index]
            let days = config.analysisWindowDays
            cards.append(InsightCard(
                id: "hypo-weekday-\(index)",
                severity: .attention,
                category: .hypoWeekday,
                headline: String(localized: "\(dayName)s have had \(count) low episodes in the last \(days) days"),
                body: String(
                    localized: "Lows have been noticeably more frequent on \(dayName)s than on other days. Consider reviewing what tends to be different on \(dayName)s — activity, meals, or schedule — with your care team."
                ),
                evidenceLine: evidenceLine(count: count, days: days),
                sfSymbol: "calendar.badge.exclamationmark"
            ))
        }
        return cards
    }

    // MARK: - Detector 3: post-meal spikes by food

    static func detectPostMealSpikes(
        carbs: [CarbSample],
        sortedGlucose: [GlucoseSample],
        config: InsightsConfig
    ) -> [InsightCard] {
        let noted = carbs.compactMap { sample -> (key: String, sample: CarbSample)? in
            guard let note = sample.note?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                  !note.isEmpty else { return nil }
            return (note, sample)
        }
        let groups = Dictionary(grouping: noted, by: \.key)

        var cards: [InsightCard] = []
        for (note, entries) in groups where entries.count >= config.minOccurrences {
            var deltas: [Double] = []
            for entry in entries {
                guard let baseline = nearestGlucose(to: entry.sample.date, in: sortedGlucose, tolerance: 15 * 60),
                      let after = nearestGlucose(
                          to: entry.sample.date.addingTimeInterval(2 * 3600),
                          in: sortedGlucose,
                          tolerance: 30 * 60
                      )
                else { continue }
                deltas.append(Double(after.glucose - baseline.glucose))
            }
            guard deltas.count >= config.minOccurrences else { continue }

            let medianDelta = median(deltas)
            guard medianDelta > Double(config.postMealRiseThreshold) else { continue }

            let rise = config.glucoseFormatter(Int(medianDelta.rounded()))
            let mealCount = deltas.count
            cards.append(InsightCard(
                id: "meal-\(note)",
                severity: .notable,
                category: .mealResponse,
                headline: String(localized: "After '\(note)', glucose typically rises by \(rise) within 2 hours"),
                body: String(
                    localized: "Across \(mealCount) meals logged as '\(note)', the median 2-hour glucose rise was \(rise). Consider discussing strategies for this meal — timing, splitting the dose, or the carb estimate — with your care team."
                ),
                evidenceLine: evidenceLine(count: mealCount, days: config.analysisWindowDays),
                sfSymbol: "fork.knife"
            ))
        }
        return cards.sorted { $0.id < $1.id }
    }

    // MARK: - Detector 4: basal friction windows

    private struct DayHour: Hashable {
        let day: Date
        let hour: Int
    }

    static func detectBasalFrictionWindows(
        determinations: [DeterminationSample],
        config: InsightsConfig,
        calendar: Calendar
    ) -> [InsightCard] {
        struct Cell {
            var rateSum = 0.0
            var scheduledSum = 0.0
            var count = 0
        }

        var cells: [DayHour: Cell] = [:]
        for sample in determinations where sample.enacted {
            guard let scheduled = sample.scheduledBasal, scheduled > 0 else { continue }
            let rate = sample.rate ?? scheduled
            let key = DayHour(day: calendar.startOfDay(for: sample.date), hour: calendar.component(.hour, from: sample.date))
            var cell = cells[key, default: Cell()]
            cell.rateSum += rate
            cell.scheduledSum += scheduled
            cell.count += 1
            cells[key] = cell
        }

        struct HourStat {
            var below = 0
            var above = 0
            var total = 0
        }

        var hourStats = [HourStat](repeating: HourStat(), count: 24)
        for (key, cell) in cells {
            guard cell.count > 0, cell.scheduledSum > 0 else { continue }
            let meanRate = cell.rateSum / Double(cell.count)
            let meanScheduled = cell.scheduledSum / Double(cell.count)
            let deviation = (meanRate - meanScheduled) / meanScheduled
            hourStats[key.hour].total += 1
            if deviation < -0.3 {
                hourStats[key.hour].below += 1
            } else if deviation > 0.3 {
                hourStats[key.hour].above += 1
            }
        }

        struct FlaggedHour {
            let hour: Int
            let reduced: Bool
            let days: Int
            let total: Int
        }

        var flagged: [FlaggedHour] = []
        for hour in 0 ..< 24 {
            let stat = hourStats[hour]
            guard stat.total >= config.minOccurrences else { continue }
            if Double(stat.below) / Double(stat.total) >= 0.7 {
                flagged.append(FlaggedHour(hour: hour, reduced: true, days: stat.below, total: stat.total))
            } else if Double(stat.above) / Double(stat.total) >= 0.7 {
                flagged.append(FlaggedHour(hour: hour, reduced: false, days: stat.above, total: stat.total))
            }
        }

        // Merge adjacent flagged hours with the same direction into windows.
        var cards: [InsightCard] = []
        var index = 0
        while index < flagged.count {
            var end = index
            while end + 1 < flagged.count,
                  flagged[end + 1].hour == flagged[end].hour + 1,
                  flagged[end + 1].reduced == flagged[index].reduced
            {
                end += 1
            }
            let window = flagged[index ... end]
            let representative = window.max { $0.days < $1.days } ?? flagged[index]
            let label = hourRangeLabel(from: flagged[index].hour, toExclusive: flagged[end].hour + 1)
            let reduced = flagged[index].reduced
            let days = representative.days
            let total = representative.total

            let headline = reduced
                ? String(localized: "Basal was often reduced between \(label)")
                : String(localized: "Basal was often raised between \(label)")
            let body = reduced
                ? String(
                    localized: "Between \(label) the algorithm reduced basal delivery on \(days) of \(total) days — basal may be set higher than needed there. Discuss with your care team before changing any settings."
                )
                : String(
                    localized: "Between \(label) the algorithm raised basal delivery on \(days) of \(total) days — basal may be set lower than needed there. Discuss with your care team before changing any settings."
                )

            cards.append(InsightCard(
                id: "basal-\(flagged[index].hour)-\(reduced ? "reduced" : "raised")",
                severity: .attention,
                category: .basalFit,
                headline: headline,
                body: body,
                evidenceLine: evidenceLine(count: days, days: config.analysisWindowDays),
                sfSymbol: "chart.xyaxis.line"
            ))
            index = end + 1
        }
        return cards
    }

    // MARK: - Detector 5: overnight drift

    static func detectOvernightDrift(
        sortedGlucose: [GlucoseSample],
        config: InsightsConfig,
        calendar: Calendar
    ) -> [InsightCard] {
        var midnightByDay: [Date: [Int]] = [:]
        var earlyByDay: [Date: [Int]] = [:]
        for sample in sortedGlucose {
            let hour = calendar.component(.hour, from: sample.date)
            let day = calendar.startOfDay(for: sample.date)
            if hour == 0 {
                midnightByDay[day, default: []].append(sample.glucose)
            } else if hour == 5 {
                earlyByDay[day, default: []].append(sample.glucose)
            }
        }

        var deltas: [Double] = []
        for (day, midnightValues) in midnightByDay {
            guard let earlyValues = earlyByDay[day], !midnightValues.isEmpty, !earlyValues.isEmpty else { continue }
            let midnightMean = Double(midnightValues.reduce(0, +)) / Double(midnightValues.count)
            let earlyMean = Double(earlyValues.reduce(0, +)) / Double(earlyValues.count)
            deltas.append(earlyMean - midnightMean)
        }
        guard deltas.count >= config.minOccurrences else { return [] }

        let threshold = Double(config.overnightDriftThreshold)
        let risingNights = deltas.filter { $0 > threshold }.count
        let fallingNights = deltas.filter { $0 < -threshold }.count
        let totalNights = deltas.count
        let medianDelta = median(deltas)

        if Double(risingNights) / Double(totalNights) >= 0.6 {
            let rise = config.glucoseFormatter(Int(abs(medianDelta).rounded()))
            return [InsightCard(
                id: "overnight-climb",
                severity: .notable,
                category: .overnight,
                headline: String(localized: "Glucose tends to climb overnight (median +\(rise))"),
                body: String(
                    localized: "On \(risingNights) of \(totalNights) nights, glucose was noticeably higher around 5 AM than around midnight. Consider reviewing overnight basal rates in this window with your care team."
                ),
                evidenceLine: evidenceLine(count: risingNights, days: config.analysisWindowDays),
                sfSymbol: "moon.zzz.fill"
            )]
        }
        if Double(fallingNights) / Double(totalNights) >= 0.6 {
            let fall = config.glucoseFormatter(Int(abs(medianDelta).rounded()))
            return [InsightCard(
                id: "overnight-fall",
                severity: .notable,
                category: .overnight,
                headline: String(localized: "Glucose tends to fall overnight (median -\(fall))"),
                body: String(
                    localized: "On \(fallingNights) of \(totalNights) nights, glucose was noticeably lower around 5 AM than around midnight. Consider reviewing overnight basal rates in this window with your care team."
                ),
                evidenceLine: evidenceLine(count: fallingNights, days: config.analysisWindowDays),
                sfSymbol: "moon.zzz.fill"
            )]
        }
        return []
    }

    // MARK: - Detector 6: hypo followed by rebound high

    static func detectHypoRebound(
        episodes: [LowEpisode],
        sortedGlucose: [GlucoseSample],
        config: InsightsConfig
    ) -> [InsightCard] {
        guard episodes.count >= config.minOccurrences else { return [] }

        let reboundCount = episodes.filter { episode in
            let windowEnd = episode.end.addingTimeInterval(2 * 3600)
            return sortedGlucose.contains { sample in
                sample.date > episode.end && sample.date <= windowEnd && sample.glucose > config.reboundThreshold
            }
        }.count

        guard Double(reboundCount) / Double(episodes.count) >= 0.5 else { return [] }

        let rebound = config.glucoseFormatter(config.reboundThreshold)
        return [InsightCard(
            id: "hypo-rebound",
            severity: .info,
            category: .rebound,
            headline: String(localized: "Rebound highs often follow lows"),
            body: String(
                localized: "\(reboundCount) of \(episodes.count) low episodes were followed within 2 hours by a reading above \(rebound). Consider reviewing the size of your low treatments with your care team."
            ),
            evidenceLine: evidenceLine(count: reboundCount, days: config.analysisWindowDays),
            sfSymbol: "arrow.up.arrow.down"
        )]
    }

    // MARK: - Helpers

    static func evidenceLine(count: Int, days: Int) -> String {
        String(localized: "Seen \(count) times in the last \(days) days")
    }

    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let count = sorted.count
        if count.isMultiple(of: 2) {
            return (sorted[count / 2 - 1] + sorted[count / 2]) / 2
        }
        return sorted[count / 2]
    }

    /// Nearest reading to `date` within `tolerance`, or nil. Requires `sortedGlucose` ascending by date.
    static func nearestGlucose(to date: Date, in sortedGlucose: [GlucoseSample], tolerance: TimeInterval) -> GlucoseSample? {
        guard !sortedGlucose.isEmpty else { return nil }
        var low = 0
        var high = sortedGlucose.count - 1
        while low < high {
            let mid = (low + high) / 2
            if sortedGlucose[mid].date < date {
                low = mid + 1
            } else {
                high = mid
            }
        }
        var best: GlucoseSample?
        for index in [low - 1, low, low + 1] where sortedGlucose.indices.contains(index) {
            let candidate = sortedGlucose[index]
            let distance = abs(candidate.date.timeIntervalSince(date))
            guard distance <= tolerance else { continue }
            if let current = best {
                if distance < abs(current.date.timeIntervalSince(date)) {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }
        return best
    }

    static func hourLabel(_ hour: Int) -> String {
        let normalized = ((hour % 24) + 24) % 24
        switch normalized {
        case 0: return "12 AM"
        case 1 ... 11: return "\(normalized) AM"
        case 12: return "12 PM"
        default: return "\(normalized - 12) PM"
        }
    }

    /// "3 AM" + "6 AM" -> "3–6 AM"; falls back to "11 PM–2 AM" across meridiem or midnight/noon.
    static func hourRangeLabel(from start: Int, toExclusive end: Int) -> String {
        let startLabel = hourLabel(start)
        let endLabel = hourLabel(end)
        let startParts = startLabel.split(separator: " ")
        let endParts = endLabel.split(separator: " ")
        if startParts.count == 2, endParts.count == 2, startParts[1] == endParts[1],
           startParts[0] != "12", endParts[0] != "12"
        {
            return "\(startParts[0])–\(endLabel)"
        }
        return "\(startLabel)–\(endLabel)"
    }
}
