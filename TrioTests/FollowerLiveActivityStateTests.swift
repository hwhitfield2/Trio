import Foundation
import Testing

@testable import Trio

@Suite("Follower Live Activity State Tests") struct FollowerLiveActivityStateTests {
    private func snapshot(
        units: String = "mg/dL",
        readings: [(sgv: Int, minutesAgo: Double, direction: String?)] = [(120, 0, "Flat")],
        iob: Double? = 1.25,
        cob: Double? = 18.4,
        low: Double = 70,
        high: Double = 180,
        now: TimeInterval = 1_700_000_000
    ) -> FollowerStatusSnapshot {
        FollowerStatusSnapshot(
            type: "status",
            timestamp: now,
            units: units,
            readings: readings.map {
                FollowerStatusSnapshot.Reading(
                    sgv: $0.sgv,
                    date: now - $0.minutesAgo * 60,
                    direction: $0.direction
                )
            },
            iob: iob,
            cob: cob,
            lastLoop: now,
            eventualBG: 110,
            tempTarget: nil,
            override: nil,
            maxBolus: 10,
            maxCarbs: 250,
            low: low,
            high: high
        )
    }

    @Test("Content state uses the key names ActivityKit decodes on the follower")
    func wireFieldNames() throws {
        // These names must match FollowerActivityAttributes.ContentState in the
        // follower app. ActivityKit drops a payload it cannot decode, and the
        // drop is silent, so this test is the only thing standing between a
        // rename and a Lock Screen that quietly stops updating.
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot()))
        let json = try state.asJSONObject()

        #expect(Set(json.keys) == [
            "bg",
            "direction",
            "change",
            "iob",
            "cob",
            "readingDate",
            "low",
            "high",
            "chart"
        ])

        let chart = try #require(json["chart"] as? [[String: Any]])
        #expect(Set(chart[0].keys) == ["v", "t"])
    }

    @Test("Formats mg/dL exactly like the follower app does") func mgdlFormatting() throws {
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot(
            readings: [(120, 0, "FortyFiveUp"), (114, 5, "Flat")]
        )))

        #expect(state.bg == "120")
        #expect(state.direction == "↗")
        #expect(state.change == "+6")
        // 1.25 rounds up, the way Dart's toStringAsFixed does, not to even the
        // way printf would.
        #expect(state.iob == "1.3")
        #expect(state.cob == "18")
        #expect(state.low == 70)
        #expect(state.high == 180)
    }

    @Test("Converts to mmol/L with one decimal, thresholds included") func mmolFormatting() throws {
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot(
            units: "mmol/L",
            readings: [(120, 0, "SingleDown"), (138, 5, "Flat")]
        )))

        #expect(state.bg == "6.7")
        #expect(state.direction == "↓")
        #expect(state.change == "-1.0")
        #expect(state.low == 3.9)
        #expect(state.high == 10.0)
        #expect(state.chart.first?.v == 6.7)
    }

    @Test("Missing insulin and carbs render as dashes, not zeros") func missingValues() throws {
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot(iob: nil, cob: nil)))
        #expect(state.iob == "--")
        #expect(state.cob == "--")
    }

    @Test("A single reading has no delta to show") func singleReading() throws {
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot()))
        #expect(state.change == "")
    }

    @Test("Chart is trimmed to the ActivityKit payload budget, newest first") func chartTrimming() throws {
        let readings = (0 ..< 60).map { (sgv: 100 + $0, minutesAgo: Double($0) * 5, direction: "Flat") }
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot(readings: readings)))

        #expect(state.chart.count == FollowerLiveActivityState.maxChartPoints)
        #expect(state.chart.first?.v == 100)
        #expect(state.chart.last?.v == 123)
    }

    @Test("A snapshot with no readings has nothing to show") func noReadings() {
        #expect(FollowerLiveActivityState.from(snapshot: snapshot(readings: [])) == nil)
    }

    @Test("Stale date is six minutes after the reading, matching the widgets") func staleDate() throws {
        let state = try #require(FollowerLiveActivityState.from(snapshot: snapshot()))
        #expect(state.staleDate.timeIntervalSince1970 == state.readingDate + 6 * 60)
    }

    @Test("Halves round away from zero, as they do in the app") func halfRounding() {
        // Verified against Dart: 1.25 and 0.25 are exact halves and round up,
        // 0.35 is not (its double is a hair below) and rounds down. Both sides
        // agree because both round the binary value, not the decimal it looks
        // like.
        #expect(FollowerLiveActivityState.oneDecimal(1.25) == "1.3")
        #expect(FollowerLiveActivityState.oneDecimal(-1.25) == "-1.3")
        #expect(FollowerLiveActivityState.oneDecimal(0.25) == "0.3")
        #expect(FollowerLiveActivityState.oneDecimal(0.35) == "0.3")
        #expect(FollowerLiveActivityState.oneDecimal(2) == "2.0")
    }

    @Test("Trend arrows match the follower app's glyphs") func trendArrows() {
        #expect(FollowerLiveActivityState.trendArrow(for: "DoubleUp") == "⇈")
        #expect(FollowerLiveActivityState.trendArrow(for: "SingleUp") == "↑")
        #expect(FollowerLiveActivityState.trendArrow(for: "FortyFiveUp") == "↗")
        #expect(FollowerLiveActivityState.trendArrow(for: "Flat") == "→")
        #expect(FollowerLiveActivityState.trendArrow(for: "FortyFiveDown") == "↘")
        #expect(FollowerLiveActivityState.trendArrow(for: "SingleDown") == "↓")
        #expect(FollowerLiveActivityState.trendArrow(for: "DoubleDown") == "⇊")
        #expect(FollowerLiveActivityState.trendArrow(for: nil) == "")
        #expect(FollowerLiveActivityState.trendArrow(for: "NONE") == "")
    }
}
