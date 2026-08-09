import Charts
import SwiftUI

/// Horizontal stacked time-in-ranges bar with the five standard AGP bands.
/// Used on screen and inside the PDF.
struct ClinicReportTIRBar: View {
    let ranges: AGPTimeInRanges
    let units: GlucoseUnits

    static let veryLowColor = Color(red: 0.55, green: 0.0, blue: 0.0)
    static let lowColor = Color.red
    static let inRangeColor = Color.green
    static let highColor = Color.yellow
    static let veryHighColor = Color.orange

    private var segments: [(label: String, percent: Double, color: Color)] {
        [
            (
                "<\(AGPCalculator.veryLowThreshold.formatted(for: units))",
                ranges.veryLowPercent,
                Self.veryLowColor
            ),
            (
                "\(AGPCalculator.veryLowThreshold.formatted(for: units))–" +
                    "\((AGPCalculator.lowThreshold - 1).formatted(for: units))",
                ranges.lowPercent,
                Self.lowColor
            ),
            (
                "\(AGPCalculator.lowThreshold.formatted(for: units))–\(AGPCalculator.highThreshold.formatted(for: units))",
                ranges.inRangePercent,
                Self.inRangeColor
            ),
            (
                "\((AGPCalculator.highThreshold + 1).formatted(for: units))–" +
                    "\(AGPCalculator.veryHighThreshold.formatted(for: units))",
                ranges.highPercent,
                Self.highColor
            ),
            (
                ">\(AGPCalculator.veryHighThreshold.formatted(for: units))",
                ranges.veryHighPercent,
                Self.veryHighColor
            )
        ]
    }

    private var hasData: Bool {
        segments.contains { $0.percent > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if hasData {
                        ForEach(segments, id: \.label) { segment in
                            Rectangle()
                                .fill(segment.color)
                                .frame(width: geometry.size.width * CGFloat(max(segment.percent, 0)) / 100)
                        }
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.3))
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            HStack(alignment: .top, spacing: 8) {
                ForEach(segments, id: \.label) { segment in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 3) {
                            Circle().fill(segment.color).frame(width: 7, height: 7)
                            Text(segment.label)
                        }
                        Text("\(segment.percent.formatted(.number.precision(.fractionLength(1))))%")
                            .bold()
                    }
                    .font(.caption2)
                }
            }
        }
    }
}

/// Page 1 of the PDF: title, metrics grid, time-in-ranges bar and the AGP chart.
struct ClinicReportSummaryPage: View {
    let data: AGPReportData
    let units: GlucoseUnits

    private var dateRangeText: String {
        let start = data.periodStart.formatted(date: .abbreviated, time: .omitted)
        let end = data.periodEnd.formatted(date: .abbreviated, time: .omitted)
        return "\(start) – \(end) (\(data.periodDays) days)"
    }

    private func glucoseText(_ mgdL: Double) -> String {
        let converted = mgdL.asUnit(units)
        let digits = units == .mgdL ? 0 : 1
        return converted.formatted(.number.precision(.fractionLength(digits))) + " \(units.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Ambulatory Glucose Profile (AGP) Report")
                .font(.title2)
                .bold()

            HStack {
                Text(dateRangeText)
                Spacer()
                Text("Generated \(Date().formatted(date: .abbreviated, time: .shortened))")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                GridRow {
                    metricCell(
                        title: String(localized: "CGM Active"),
                        value: "\(data.cgmActivePercent.formatted(.number.precision(.fractionLength(0))))%"
                    )
                    metricCell(title: String(localized: "Average Glucose"), value: glucoseText(data.meanGlucose))
                    metricCell(
                        title: String(localized: "GMI"),
                        value: "\(data.gmiPercent.formatted(.number.precision(.fractionLength(1))))%"
                    )
                }
                GridRow {
                    metricCell(
                        title: String(localized: "Glucose Variability (CV)"),
                        value: "\(data.cvPercent.formatted(.number.precision(.fractionLength(1))))%" +
                            (data.isHighVariability ? " (\(String(localized: "high")))" : "")
                    )
                    metricCell(
                        title: String(localized: "Avg. Total Daily Insulin"),
                        value: data.averageTDD
                            .map { "\($0.formatted(.number.precision(.fractionLength(1)))) \(String(localized: "U"))" } ?? "–"
                    )
                    metricCell(
                        title: String(localized: "Avg. Daily Carbs"),
                        value: data.averageDailyCarbs
                            .map { "\($0.formatted(.number.precision(.fractionLength(0)))) \(String(localized: "g"))" } ?? "–"
                    )
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Time in Ranges")
                    .font(.headline)
                ClinicReportTIRBar(ranges: data.timeInRanges, units: units)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Ambulatory Glucose Profile")
                    .font(.headline)
                Text("Median, 25–75% and 5–95% of glucose readings by time of day.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                AGPChartView(bins: data.timeBins, units: units)
                    .frame(height: 280)
            }

            Spacer(minLength: 0)

            Text("Generated by Trio — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: ClinicReportPDFRenderer.pageSize.width, height: ClinicReportPDFRenderer.pageSize.height)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }

    private func metricCell(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .bold()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Follow-up PDF pages: up to 14 daily glucose thumbnails (7 rows x 2 columns).
struct ClinicReportDailyPage: View {
    let days: [AGPDailySeries]
    let units: GlucoseUnits

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Daily Glucose Profiles")
                .font(.headline)

            VStack(spacing: 10) {
                ForEach(Array(stride(from: 0, to: days.count, by: 2)), id: \.self) { index in
                    HStack(spacing: 14) {
                        ClinicReportDailyThumbnail(day: days[index], units: units)
                        if index + 1 < days.count {
                            ClinicReportDailyThumbnail(day: days[index + 1], units: units)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 92)
                }
            }

            Spacer(minLength: 0)

            Text("Generated by Trio — not medical advice.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(width: ClinicReportPDFRenderer.pageSize.width, height: ClinicReportPDFRenderer.pageSize.height)
        .background(Color.white)
        .foregroundStyle(Color.black)
    }
}

/// One mini chart of a single day's glucose readings with 70/180 rule lines.
struct ClinicReportDailyThumbnail: View {
    let day: AGPDailySeries
    let units: GlucoseUnits

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                .font(.caption2)
                .bold()

            Chart {
                ForEach(day.readings, id: \.date) { reading in
                    LineMark(
                        x: .value("Time", reading.date),
                        y: .value("Glucose", Double(reading.glucose).asUnit(units))
                    )
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .foregroundStyle(Color.blue)
                }

                RuleMark(y: .value("Low", Double(AGPCalculator.lowThreshold).asUnit(units)))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.green)

                RuleMark(y: .value("High", Double(AGPCalculator.highThreshold).asUnit(units)))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(Color.green)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: 40.0.asUnit(units) ... 400.0.asUnit(units))
            .chartXScale(domain: day.date ... day.date.addingTimeInterval(24 * 60 * 60))
        }
        .frame(maxWidth: .infinity)
    }
}
