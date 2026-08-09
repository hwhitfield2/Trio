import Foundation
import Testing

@testable import Trio

@Suite("Insights Engine Tests") struct InsightsEngineTests {
    /// Fixed UTC calendar with an English locale so weekday names and AM/PM labels are deterministic.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
        return calendar
    }

    /// June 2025: the 1st is a Sunday, so the 6th, 13th, 20th and 27th are Fridays.
    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2025, month: 6, day: day, hour: hour, minute: minute))!
    }

    private var config: InsightsConfig {
        var config = InsightsConfig()
        config.analysisWindowDays = 30
        return config
    }

    // MARK: - Episode grouping

    @Test("Low readings more than 30 minutes apart form separate episodes") func testEpisodeGrouping() {
        let readings = [
            GlucoseSample(date: date(day: 1, hour: 10, minute: 0), glucose: 60),
            GlucoseSample(date: date(day: 1, hour: 10, minute: 10), glucose: 55),
            GlucoseSample(date: date(day: 1, hour: 11, minute: 0), glucose: 65),
            GlucoseSample(date: date(day: 1, hour: 12, minute: 0), glucose: 110)
        ]
        let episodes = InsightsEngine.lowEpisodes(in: readings, config: config)

        #expect(episodes.count == 2)
        #expect(episodes[0].start == date(day: 1, hour: 10, minute: 0))
        #expect(episodes[0].end == date(day: 1, hour: 10, minute: 10))
        #expect(episodes[0].minGlucose == 55)
        #expect(episodes[1].start == date(day: 1, hour: 11, minute: 0))
    }

    // MARK: - Detectors 1 + 2: planted 3 AM lows on four Fridays

    @Test("Repeated 3 AM Friday lows trigger the time-of-day and weekday detectors") func testHypoClustering() {
        var readings: [GlucoseSample] = []
        // Background readings at noon, in range, every day.
        for day in 1 ... 28 {
            readings.append(GlucoseSample(date: date(day: day, hour: 12), glucose: 110))
        }
        // One low episode at 3 AM on each of the four Fridays.
        for day in [6, 13, 20, 27] {
            for minute in [0, 10, 20] {
                readings.append(GlucoseSample(date: date(day: day, hour: 3, minute: minute), glucose: 60))
            }
        }

        let cards = InsightsEngine.analyze(
            glucose: readings,
            carbs: [],
            determinations: [],
            config: config,
            calendar: calendar
        )

        #expect(cards.count == 2)

        let timeCard = cards.first { $0.category == .hypoTiming }
        #expect(timeCard != nil)
        #expect(timeCard?.headline.contains("3–6 AM") == true)
        #expect(timeCard?.evidenceLine.contains("4") == true)
        #expect(timeCard?.evidenceLine.contains("30") == true)

        let weekdayCard = cards.first { $0.category == .hypoWeekday }
        #expect(weekdayCard != nil)
        #expect(weekdayCard?.headline.contains("Friday") == true)
        #expect(weekdayCard?.headline.contains("4") == true)
    }

    // MARK: - Detector 3: post-meal spikes by food

    @Test("Repeated 'pizza' entries with +90 mg/dL 2-hour deltas are flagged") func testPostMealSpikes() {
        var readings: [GlucoseSample] = []
        var carbs: [CarbSample] = []
        // Note normalization: mixed case and whitespace should group together.
        for (day, note) in [(1, "Pizza"), (2, " pizza "), (3, "PIZZA")] {
            carbs.append(CarbSample(date: date(day: day, hour: 18), carbs: 60, note: note))
            readings.append(GlucoseSample(date: date(day: day, hour: 18), glucose: 120))
            readings.append(GlucoseSample(date: date(day: day, hour: 20), glucose: 210))
        }

        let cards = InsightsEngine.analyze(
            glucose: readings,
            carbs: carbs,
            determinations: [],
            config: config,
            calendar: calendar
        )

        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.category == .mealResponse)
        #expect(card.headline.contains("pizza"))
        #expect(card.headline.contains("90 mg/dL"))
        #expect(card.evidenceLine.contains("3"))
    }

    @Test("Meals without notes never produce meal cards") func testUnnotedMealsIgnored() {
        let carbs = (1 ... 5).map { day in
            CarbSample(date: date(day: day, hour: 18), carbs: 60, note: nil)
        }
        let cards = InsightsEngine.detectPostMealSpikes(carbs: carbs, sortedGlucose: [], config: config)
        #expect(cards.isEmpty)
    }

    // MARK: - Detector 4: basal friction windows

    @Test("Nightly zero-temps against a 1.0 U/h schedule flag a reduced-basal window") func testBasalFriction() {
        var determinations: [DeterminationSample] = []
        for day in 1 ... 10 {
            for hour in [2, 3, 4] {
                for minute in [0, 30] {
                    // Zero-temp on 8 of 10 days, scheduled rate on the other 2.
                    let rate = day <= 8 ? 0.0 : 1.0
                    determinations.append(DeterminationSample(
                        date: date(day: day, hour: hour, minute: minute),
                        rate: rate,
                        scheduledBasal: 1.0,
                        enacted: true
                    ))
                }
            }
        }

        let cards = InsightsEngine.analyze(
            glucose: [],
            carbs: [],
            determinations: determinations,
            config: config,
            calendar: calendar
        )

        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.category == .basalFit)
        #expect(card.severity == .attention)
        #expect(card.headline.contains("reduced"))
        #expect(card.headline.contains("2–5 AM"))
        #expect(card.body.contains("8 of 10"))
        #expect(card.body.contains("care team"))
    }

    // MARK: - Detector 5: overnight drift

    @Test("A consistent overnight climb is reported with its median rise") func testOvernightDrift() {
        var readings: [GlucoseSample] = []
        for day in 1 ... 10 {
            readings.append(GlucoseSample(date: date(day: day, hour: 0, minute: 30), glucose: 100))
            readings.append(GlucoseSample(date: date(day: day, hour: 5, minute: 30), glucose: 160))
        }

        let cards = InsightsEngine.analyze(
            glucose: readings,
            carbs: [],
            determinations: [],
            config: config,
            calendar: calendar
        )

        #expect(cards.count == 1)
        let card = cards[0]
        #expect(card.category == .overnight)
        #expect(card.headline.contains("climb"))
        #expect(card.headline.contains("+60 mg/dL"))
    }

    // MARK: - Detector 6: hypo followed by rebound high

    @Test("Rebound highs after most lows produce an info card") func testHypoRebound() {
        var readings: [GlucoseSample] = []
        for day in 1 ... 4 {
            readings.append(GlucoseSample(date: date(day: day, hour: 10), glucose: 55))
            readings.append(GlucoseSample(date: date(day: day, hour: 11), glucose: 260))
            readings.append(GlucoseSample(date: date(day: day, hour: 15), glucose: 110))
        }

        let cards = InsightsEngine.analyze(
            glucose: readings,
            carbs: [],
            determinations: [],
            config: config,
            calendar: calendar
        )

        let reboundCard = cards.first { $0.category == .rebound }
        #expect(reboundCard != nil)
        #expect(reboundCard?.severity == .info)
        #expect(reboundCard?.body.contains("4 of 4") == true)
        // Cards are sorted most severe first, so the info card comes last.
        #expect(cards.last?.category == .rebound)
        #expect(cards.first?.severity == .attention)
    }

    // MARK: - Flat data

    @Test("Flat, in-range data yields zero cards") func testFlatData() {
        var readings: [GlucoseSample] = []
        for day in 1 ... 14 {
            for hour in 0 ..< 24 {
                for minute in [0, 30] {
                    readings.append(GlucoseSample(date: date(day: day, hour: hour, minute: minute), glucose: 110))
                }
            }
        }
        let carbs = (1 ... 14).map { day in
            CarbSample(date: date(day: day, hour: 12), carbs: 40, note: nil)
        }
        var determinations: [DeterminationSample] = []
        for day in 1 ... 14 {
            for hour in 0 ..< 24 {
                determinations.append(DeterminationSample(
                    date: date(day: day, hour: hour),
                    rate: 1.0,
                    scheduledBasal: 1.0,
                    enacted: true
                ))
            }
        }

        let cards = InsightsEngine.analyze(
            glucose: readings,
            carbs: carbs,
            determinations: determinations,
            config: config,
            calendar: calendar
        )

        #expect(cards.isEmpty)
    }

    // MARK: - Helpers

    @Test("Hour range labels compress a shared meridiem") func testHourRangeLabels() {
        #expect(InsightsEngine.hourRangeLabel(from: 3, toExclusive: 6) == "3–6 AM")
        #expect(InsightsEngine.hourRangeLabel(from: 15, toExclusive: 18) == "3–6 PM")
        #expect(InsightsEngine.hourRangeLabel(from: 21, toExclusive: 24) == "9 PM–12 AM")
        #expect(InsightsEngine.hourRangeLabel(from: 0, toExclusive: 3) == "12 AM–3 AM")
    }

    @Test("Nearest glucose lookup respects the tolerance window") func testNearestGlucose() {
        let readings = [
            GlucoseSample(date: date(day: 1, hour: 10), glucose: 100),
            GlucoseSample(date: date(day: 1, hour: 12), glucose: 150)
        ]
        let nearMatch = InsightsEngine.nearestGlucose(
            to: date(day: 1, hour: 10, minute: 10),
            in: readings,
            tolerance: 15 * 60
        )
        #expect(nearMatch?.glucose == 100)

        let outOfTolerance = InsightsEngine.nearestGlucose(
            to: date(day: 1, hour: 11),
            in: readings,
            tolerance: 15 * 60
        )
        #expect(outOfTolerance == nil)
    }
}
