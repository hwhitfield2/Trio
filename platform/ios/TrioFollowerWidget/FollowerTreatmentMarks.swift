import Charts
import SwiftUI

/// A bolus or carb entry ready to be drawn: when it happened, how big a mark it
/// gets, and which way that mark points.
///
/// Both payloads — the widgets' and the Live Activity's — carry the same two
/// arrays, and both charts draw them the same way, so the arithmetic lives here
/// once. Keep in step with `GlucoseChart` in the app itself, which draws the
/// same markers against the same readings.
struct FollowerChartMark: Identifiable {
    let id: Int
    let date: Date
    /// The glucose value of the reading this sits against, in display units.
    let value: Double
    let isBolus: Bool
    /// Point size of the triangle.
    let size: CGFloat

    /// Trio's own insulin blue, and the orange it draws carbs in.
    var color: Color {
        isBolus ? Color(red: 0.118, green: 0.588, blue: 0.988) : .orange
    }
}

enum FollowerTreatmentMarks {
    /// Marks for every treatment that has a reading to sit against.
    ///
    /// A treatment has no glucose value of its own, so it is drawn at the
    /// height of the reading nearest it in time — the same thing Trio's chart
    /// does, and the only arrangement that says which reading it belongs to.
    /// Anything outside the plotted window is dropped rather than pinned to an
    /// end, where it would claim a reading it has nothing to do with.
    static func marks(
        boluses: [(date: Date, units: Double)],
        carbs: [(date: Date, grams: Double)],
        points: [(date: Date, value: Double)]
    ) -> [FollowerChartMark] {
        guard let first = points.map(\.date).min(), let last = points.map(\.date).max() else {
            return []
        }
        // Half a reading's gap of slack at each end, so one logged just before
        // the oldest plotted reading still belongs to it.
        let slack = points.count > 1
            ? last.timeIntervalSince(first) / Double(points.count - 1) / 2
            : 0

        func value(at date: Date) -> Double? {
            guard date >= first.addingTimeInterval(-slack),
                  date <= last.addingTimeInterval(slack)
            else { return nil }
            return points.min {
                abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
            }?.value
        }

        var marks: [FollowerChartMark] = []
        for bolus in boluses {
            guard let value = value(at: bolus.date) else { continue }
            marks.append(FollowerChartMark(
                id: marks.count,
                date: bolus.date,
                value: value,
                isBolus: true,
                // 1 U is a small mark and 10 U a conspicuous one; past that the
                // size stops meaning anything on a chart this size.
                size: min(max(7 + bolus.units * 1.2, 7), 14)
            ))
        }
        for carb in carbs {
            guard let value = value(at: carb.date) else { continue }
            marks.append(FollowerChartMark(
                id: marks.count,
                date: carb.date,
                value: value,
                isBolus: false,
                size: min(max(7 + carb.grams * 0.08, 7), 14)
            ))
        }
        return marks
    }
}

/// The marks themselves: insulin above the reading it was given for, carbs
/// below it, each pointing at it.
///
/// Offset in points rather than in glucose, because the offset that reads well
/// is a fixed distance on screen and the chart's scale is not fixed at all.
struct FollowerTreatmentChartContent: ChartContent {
    let marks: [FollowerChartMark]

    var body: some ChartContent {
        ForEach(marks) { mark in
            PointMark(
                x: .value("Time", mark.date),
                y: .value("Glucose", mark.value)
            )
            .symbol {
                Image(systemName: "arrowtriangle.down.fill")
                    .font(.system(size: mark.size))
                    .foregroundStyle(mark.color)
                    .rotationEffect(.degrees(mark.isBolus ? 0 : 180))
                    .offset(y: mark.isBolus ? -mark.size : mark.size)
            }
        }
    }
}
