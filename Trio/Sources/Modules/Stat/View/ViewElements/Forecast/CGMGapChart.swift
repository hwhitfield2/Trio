import Charts
import SwiftUI

/// Daily count of CGM delivery gaps long enough to trigger the "glucose data is stale" alert
/// (no reading stored for more than 12 minutes while the sensor session was active).
struct CGMGapChart: View {
    let gapStats: [CGMGapStats]

    /// Days with this many gaps or more are highlighted as problem days
    private static let problemThreshold = 5

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(gapStats) { stat in
                    BarMark(
                        x: .value("Day", stat.day, unit: .day),
                        y: .value("Gaps", stat.gapCount)
                    )
                    .foregroundStyle(
                        stat.gapCount >= Self.problemThreshold ? Color.red : Color.gray.opacity(0.6)
                    )
                    .annotation(position: .top, spacing: 2) {
                        Text("\(stat.gapCount)")
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                }
            }
            .chartYAxisLabel(String(localized: "Gaps > 12 min per day"))
            .frame(height: 180)

            Text(
                String(
                    localized: "Each gap means no reading reached Trio for over 12 minutes — the same threshold that triggers the stale glucose alert. Frequent gaps point to delivery problems (Bluetooth, backgrounding, range), not a stale sensor. Gaps longer than 6 hours are treated as the sensor being off and not counted."
                )
            )
            .font(.footnote)
            .foregroundStyle(Color.secondary)
        }
    }
}
