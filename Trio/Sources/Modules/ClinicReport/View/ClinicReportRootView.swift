import Charts
import SwiftUI
import Swinject

extension ClinicReport {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private func glucoseText(_ mgdL: Double) -> String {
            let converted = mgdL.asUnit(state.units)
            let digits = state.units == .mgdL ? 0 : 1
            return converted.formatted(.number.precision(.fractionLength(digits))) + " \(state.units.rawValue)"
        }

        var body: some View {
            List {
                Section(
                    header: Text("Report Period"),
                    footer: Text(
                        "A standardized Ambulatory Glucose Profile (AGP) report you can share with your care team. All data stays on this device until you share the PDF."
                    )
                ) {
                    Picker("Period", selection: $state.selectedPeriodDays) {
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.chart)

                if state.isLoading {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.chart)
                } else if let data = state.reportData {
                    metricsSection(for: data)

                    Section(header: Text("Time in Ranges")) {
                        ClinicReportTIRBar(ranges: data.timeInRanges, units: state.units)
                            .padding(.vertical, 4)
                    }
                    .listRowBackground(Color.chart)

                    Section(header: Text("Ambulatory Glucose Profile")) {
                        if data.readingsCount > 0 {
                            AGPChartView(bins: data.timeBins, units: state.units)
                                .frame(height: 220)
                                .padding(.vertical, 4)
                        } else {
                            Text("No glucose data available for the selected period.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .listRowBackground(Color.chart)
                }

                exportSection
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Clinic Report (AGP)")
            .navigationBarTitleDisplayMode(.automatic)
        }

        private func metricsSection(for data: AGPReportData) -> some View {
            Section(header: Text("Key Metrics")) {
                metricRow(
                    label: String(localized: "CGM Active"),
                    value: "\(data.cgmActivePercent.formatted(.number.precision(.fractionLength(0))))%"
                )
                metricRow(label: String(localized: "Average Glucose"), value: glucoseText(data.meanGlucose))
                metricRow(
                    label: String(localized: "GMI"),
                    value: "\(data.gmiPercent.formatted(.number.precision(.fractionLength(1))))%"
                )
                metricRow(
                    label: String(localized: "Glucose Variability (CV)"),
                    value: "\(data.cvPercent.formatted(.number.precision(.fractionLength(1))))%" +
                        (data.isHighVariability ? " (\(String(localized: "high")))" : "")
                )
                if let averageTDD = data.averageTDD {
                    metricRow(
                        label: String(localized: "Avg. Total Daily Insulin"),
                        value: "\(averageTDD.formatted(.number.precision(.fractionLength(1)))) \(String(localized: "U"))"
                    )
                }
                if let averageDailyCarbs = data.averageDailyCarbs {
                    metricRow(
                        label: String(localized: "Avg. Daily Carbs"),
                        value: "\(averageDailyCarbs.formatted(.number.precision(.fractionLength(0)))) \(String(localized: "g"))"
                    )
                }
                metricRow(label: String(localized: "Readings"), value: "\(data.readingsCount)")
            }
            .listRowBackground(Color.chart)
        }

        private func metricRow(label: String, value: String) -> some View {
            HStack {
                Text(label)
                Spacer()
                Text(value).foregroundStyle(.secondary)
            }
        }

        private var exportSection: some View {
            Section {
                Button {
                    Task { await state.generatePDF() }
                } label: {
                    HStack {
                        Text("Generate PDF")
                        Spacer()
                        if state.isGeneratingPDF {
                            ProgressView()
                        }
                    }
                }
                .disabled(state.isGeneratingPDF || state.isLoading || state.reportData == nil)

                if let url = state.pdfFileURL {
                    ShareLink(item: url) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }

                if let message = state.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .listRowBackground(Color.chart)
        }
    }
}
