import Charts
import SwiftUI

/// Grouped bar chart comparing oref's forecast error against the persistence baseline,
/// broken down by the situation the forecast was made in.
struct ForecastAccuracyChart: View {
    let stats: [ForecastAccuracyStats]
    @Binding var selectedHorizon: Int

    /// Shared with the ML pipeline: 30/60 min plus the 2/4/6-hour performance checks.
    static let horizonLabels: [(minutes: Int, label: String)] = [
        (30, String(localized: "30 min")),
        (60, String(localized: "60 min")),
        (120, String(localized: "2 h")),
        (240, String(localized: "4 h")),
        (360, String(localized: "6 h"))
    ]

    private var visibleStats: [ForecastAccuracyStats] {
        stats.filter { $0.horizonMinutes == selectedHorizon }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Horizon", selection: $selectedHorizon) {
                ForEach(Self.horizonLabels, id: \.minutes) { horizon in
                    Text(horizon.label).tag(horizon.minutes)
                }
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(visibleStats) { stat in
                    if let orefMAE = stat.orefMAE {
                        BarMark(
                            x: .value("Error", orefMAE),
                            y: .value("Situation", stat.situation.displayName)
                        )
                        .foregroundStyle(by: .value("Series", String(localized: "oref forecast")))
                        .position(by: .value("Series", String(localized: "oref forecast")))
                        .annotation(position: .trailing, spacing: 4) {
                            Text(orefMAE.formatted(.number.precision(.fractionLength(0))))
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
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

                    if let mlMAE = stat.mlMAE {
                        BarMark(
                            x: .value("Error", mlMAE),
                            y: .value("Situation", stat.situation.displayName)
                        )
                        .foregroundStyle(by: .value("Series", String(localized: "ML (shadow)")))
                        .position(by: .value("Series", String(localized: "ML (shadow)")))
                        .annotation(position: .trailing, spacing: 4) {
                            Text(mlMAE.formatted(.number.precision(.fractionLength(0))))
                                .font(.caption2)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            .chartForegroundStyleScale([
                String(localized: "oref forecast"): Color.blue,
                String(localized: "No-change baseline"): Color.gray.opacity(0.6),
                String(localized: "ML (shadow)"): Color.orange
            ])
            .chartLegend(position: .top, alignment: .leading)
            .chartXAxisLabel(String(localized: "Mean forecast error (mg/dL) — lower is better"))
            .frame(height: CGFloat(max(visibleStats.count, 1)) * 68 + 40)

            if let all = visibleStats.first(where: { $0.situation == .all }) {
                Text(
                    String(
                        localized: "\(all.sampleCount) forecasts scored over the last 2 days. Prediction curves are only kept for about 2 days, so this window cannot be extended."
                    )
                )
                .font(.footnote)
                .foregroundStyle(Color.secondary)

                if all.mlSampleCount > 0 {
                    Text(
                        String(
                            localized: "ML (shadow) is the bundled experimental model, scored on \(all.mlSampleCount) of these forecasts. It is display-only and never influences dosing."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }

                if all.orefSampleCount == 0 {
                    Text(
                        String(
                            localized: "oref's stored prediction curves do not reach this horizon, so only the ML model and the no-change baseline are compared here."
                        )
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }
            }
        }
    }
}

/// Scatter of predicted vs actual glucose; points on the diagonal were perfect forecasts.
/// oref and the ML shadow model are plotted as separate series — at the 2/4/6 h horizons
/// oref's stored curves usually end, so those horizons are mostly ML-only.
struct ForecastScatterChart: View {
    let points: [ForecastAccuracyPoint]
    let selectedHorizon: Int

    private var visiblePoints: [ForecastAccuracyPoint] {
        points.filter { $0.horizonMinutes == selectedHorizon }
    }

    private var axisUpperBound: Int {
        let maxValue = visiblePoints
            .flatMap { [$0.orefPredicted, $0.mlPredicted, $0.actual] }
            .compactMap { $0 }
            .max() ?? 200
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
                    if let orefPredicted = point.orefPredicted {
                        PointMark(
                            x: .value("Actual", point.actual),
                            y: .value("Predicted", orefPredicted)
                        )
                        .symbolSize(20)
                        .foregroundStyle(by: .value("Forecast", String(localized: "oref forecast")))
                    }
                    if let mlPredicted = point.mlPredicted {
                        PointMark(
                            x: .value("Actual", point.actual),
                            y: .value("Predicted", mlPredicted)
                        )
                        .symbolSize(20)
                        .foregroundStyle(by: .value("Forecast", String(localized: "ML (shadow)")))
                    }
                }
            }
            .chartForegroundStyleScale([
                String(localized: "oref forecast"): Color.blue.opacity(0.55),
                String(localized: "ML (shadow)"): Color.orange.opacity(0.55)
            ])
            .chartXScale(domain: 40 ... axisUpperBound)
            .chartYScale(domain: 40 ... axisUpperBound)
            .chartXAxisLabel(String(localized: "Actual glucose (mg/dL)"))
            .chartYAxisLabel(String(localized: "Predicted glucose (mg/dL)"))
            .chartLegend(position: .top, alignment: .leading)
            .aspectRatio(1, contentMode: .fit)

            Text(String(localized: "Points above the diagonal were forecast too high; below it, too low."))
                .font(.footnote)
                .foregroundStyle(Color.secondary)
        }
    }
}
