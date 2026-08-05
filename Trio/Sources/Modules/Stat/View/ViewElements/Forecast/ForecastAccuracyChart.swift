import Charts
import SwiftUI

/// Grouped bar chart comparing oref's forecast error against the persistence baseline,
/// broken down by the situation the forecast was made in.
struct ForecastAccuracyChart: View {
    let stats: [ForecastAccuracyStats]
    @Binding var selectedHorizon: Int

    private var visibleStats: [ForecastAccuracyStats] {
        stats.filter { $0.horizonMinutes == selectedHorizon }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Horizon", selection: $selectedHorizon) {
                Text(String(localized: "30 min")).tag(30)
                Text(String(localized: "60 min")).tag(60)
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(visibleStats) { stat in
                    BarMark(
                        x: .value("Error", stat.orefMAE),
                        y: .value("Situation", stat.situation.displayName)
                    )
                    .foregroundStyle(by: .value("Series", String(localized: "oref forecast")))
                    .position(by: .value("Series", String(localized: "oref forecast")))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(stat.orefMAE.formatted(.number.precision(.fractionLength(0))))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }

                    BarMark(
                        x: .value("Error", stat.persistenceMAE),
                        y: .value("Situation", stat.situation.displayName)
                    )
                    .foregroundStyle(by: .value("Series", String(localized: "No-change baseline")))
                    .position(by: .value("Series", String(localized: "No-change baseline")))
                    .annotation(position: .trailing, spacing: 4) {
                        Text(stat.persistenceMAE.formatted(.number.precision(.fractionLength(0))))
                            .font(.caption2)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
            .chartForegroundStyleScale([
                String(localized: "oref forecast"): Color.blue,
                String(localized: "No-change baseline"): Color.gray.opacity(0.6)
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxisLabel(String(localized: "Mean forecast error (mg/dL) — lower is better"))
            .frame(height: CGFloat(max(visibleStats.count, 1)) * 56 + 40)

            if let all = visibleStats.first(where: { $0.situation == .all }) {
                Text(
                    String(
                        localized: "\(all.sampleCount) forecasts scored over the last 2 days. Prediction curves are only kept for about 2 days, so this window cannot be extended."
                    )
                )
                .font(.footnote)
                .foregroundStyle(Color.secondary)
            }
        }
    }
}

/// Scatter of predicted vs actual glucose; points on the diagonal were perfect forecasts.
struct ForecastScatterChart: View {
    let points: [ForecastAccuracyPoint]
    let selectedHorizon: Int

    private var visiblePoints: [ForecastAccuracyPoint] {
        points.filter { $0.horizonMinutes == selectedHorizon }
    }

    private var axisUpperBound: Int {
        let maxValue = visiblePoints.flatMap { [$0.predicted, $0.actual] }.max() ?? 200
        return ((maxValue / 50) + 1) * 50
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach([40, axisUpperBound], id: \.self) { value in
                    LineMark(
                        x: .value("Actual", value),
                        y: .value("Predicted", value),
                        series: .value("Series", "identity")
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.secondary.opacity(0.6))
                }

                ForEach(visiblePoints) { point in
                    PointMark(
                        x: .value("Actual", point.actual),
                        y: .value("Predicted", point.predicted)
                    )
                    .symbolSize(20)
                    .foregroundStyle(Color.blue.opacity(0.55))
                }
            }
            .chartXScale(domain: 40 ... axisUpperBound)
            .chartYScale(domain: 40 ... axisUpperBound)
            .chartXAxisLabel(String(localized: "Actual glucose (mg/dL)"))
            .chartYAxisLabel(String(localized: "Predicted glucose (mg/dL)"))
            .chartLegend(.hidden)
            .aspectRatio(1, contentMode: .fit)

            Text(String(localized: "Points above the diagonal were forecast too high; below it, too low."))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }
}
