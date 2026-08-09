import Charts
import SwiftUI

/// The AGP percentile chart: 5-95 % and 25-75 % bands plus the median line,
/// with rule marks at the standard 70/180 mg/dL band limits.
/// Reusable at screen size and inside the fixed-size PDF pages.
struct AGPChartView: View {
    /// 48 half-hour time-of-day bins; `nil` entries are skipped.
    let bins: [AGPTimeBinStats?]
    let units: GlucoseUnits
    var showLegend = true

    private var presentBins: [AGPTimeBinStats] {
        bins.compactMap { $0 }
    }

    private var minYValue: Double {
        40.0.asUnit(units)
    }

    private var maxYValue: Double {
        let topMgdL = max(300.0, (presentBins.map(\.p95).max() ?? 0) + 10)
        return topMgdL.asUnit(units)
    }

    /// Maps a half-hour bin to its midpoint clock time on an arbitrary reference day.
    private func binDate(_ binIndex: Int) -> Date {
        Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(binIndex) * 30 * 60 + 15 * 60)
    }

    var body: some View {
        Chart {
            ForEach(presentBins, id: \.binIndex) { bin in
                AreaMark(
                    x: .value("Time", binDate(bin.binIndex)),
                    yStart: .value("5th Percentile", bin.p5.asUnit(units)),
                    yEnd: .value("95th Percentile", bin.p95.asUnit(units)),
                    series: .value("5-95", "5-95")
                )
                .foregroundStyle(by: .value("Series", "5-95%"))

                AreaMark(
                    x: .value("Time", binDate(bin.binIndex)),
                    yStart: .value("25th Percentile", bin.p25.asUnit(units)),
                    yEnd: .value("75th Percentile", bin.p75.asUnit(units)),
                    series: .value("25-75", "25-75")
                )
                .foregroundStyle(by: .value("Series", "25-75%"))

                LineMark(
                    x: .value("Time", binDate(bin.binIndex)),
                    y: .value("Median", bin.p50.asUnit(units)),
                    series: .value("Median", "Median")
                )
                .lineStyle(StrokeStyle(lineWidth: 2))
                .foregroundStyle(by: .value("Series", "Median"))
            }

            RuleMark(y: .value("Low Limit", Double(AGPCalculator.lowThreshold).asUnit(units)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color.green)

            RuleMark(y: .value("High Limit", Double(AGPCalculator.highThreshold).asUnit(units)))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 5]))
                .foregroundStyle(Color.green)
        }
        .chartForegroundStyleScale([
            "5-95%": Color.blue.opacity(0.25),
            "25-75%": Color.blue.opacity(0.5),
            "Median": Color.blue
        ])
        .chartLegend(showLegend ? .visible : .hidden)
        .chartYScale(domain: minYValue ... maxYValue)
        .chartYAxis {
            AxisMarks(position: .trailing) { value in
                if let glucose = value.as(Double.self) {
                    AxisValueLabel {
                        Text(
                            units == .mmolL ? glucose.formatted(.number.precision(.fractionLength(1))) : glucose
                                .formatted(.number.precision(.fractionLength(0)))
                        )
                        .font(.footnote)
                    }
                    AxisGridLine()
                }
            }
        }
        .chartYAxisLabel(alignment: .trailing) {
            Text("\(units.rawValue)")
                .font(.footnote)
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: 3)) { value in
                if value.as(Date.self) != nil {
                    AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .omitted)))
                    AxisGridLine()
                }
            }
        }
    }
}
