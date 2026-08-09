import SwiftUI
import Swinject

extension TherapyRatioCalculator {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var weightInput: Decimal = 0
        @State private var weightUnit: WeightUnit = .kg
        @State private var isISFConfirmationPresented = false
        @State private var isCarbRatioConfirmationPresented = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        enum WeightUnit: String, CaseIterable, Identifiable {
            case kg
            case lbs

            var id: String { rawValue }

            var displayName: String {
                switch self {
                case .kg: return String(localized: "kg", comment: "Kilogram unit")
                case .lbs: return String(localized: "lbs", comment: "Pound unit")
                }
            }
        }

        private var isfFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = state.units == .mgdL ? 0 : 1
            formatter.minimumFractionDigits = state.units == .mgdL ? 0 : 1
            return formatter
        }

        private var ratioFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }

        private var isfUnitLabel: String {
            state.units == .mgdL ? String(localized: "mg/dL/U") : String(localized: "mmol/L/U")
        }

        var body: some View {
            List {
                explainerSection
                dataSourceSection
                if state.effectiveTDD != nil {
                    recommendationSection
                }
                methodologySection
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("ISF & CR Calculator")
            .navigationBarTitleDisplayMode(.automatic)
            .confirmationDialog(
                "Apply Recommended Insulin Sensitivity?",
                isPresented: $isISFConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Apply", role: .destructive) {
                    state.applyRecommendedISF()
                }
            } message: {
                Text(
                    "This replaces your entire insulin sensitivity schedule with a single all-day value of \(formattedISF(state.recommendedISF)) \(isfUnitLabel). Discuss changes with your care team before applying."
                )
            }
            .confirmationDialog(
                "Apply Recommended Carb Ratio?",
                isPresented: $isCarbRatioConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Apply", role: .destructive) {
                    state.applyRecommendedCarbRatio()
                }
            } message: {
                Text(
                    "This replaces your entire carb ratio schedule with a single all-day value of \(formattedRatio(state.recommendedCarbRatio)) g/U. Discuss changes with your care team before applying."
                )
            }
        }

        // MARK: - Sections

        private var explainerSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "This calculator suggests starting points for your Insulin Sensitivity Factor (ISF) and Carb Ratio (CR) using widely taught clinical rules of thumb based on your total daily insulin dose (TDD)."
                    )
                    Text(
                        "ISF is how much one unit of insulin lowers your glucose. CR is how many grams of carbs one unit of insulin covers. If these are set too weak or too strong, Trio's glucose forecasts — including your eventual glucose — will consistently miss."
                    )
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(
                            "These are estimates, not prescriptions. Always review changes with your diabetes care team, especially as a new diabetic — insulin needs often change substantially in the first months."
                        )
                    }
                    .font(.footnote)
                }
                .font(.subheadline)
            }
            .listRowBackground(Color.chart)
        }

        private var dataSourceSection: some View {
            Section(
                header: Text("Total Daily Dose").glassCaption()
            ) {
                Picker("Estimate From", selection: $state.tddSource) {
                    ForEach(TDDSource.allCases) { source in
                        Text(source.displayName).tag(source)
                    }
                }
                .pickerStyle(.segmented)

                switch state.tddSource {
                case .pumpHistory:
                    if state.isLoadingTDD {
                        HStack {
                            ProgressView()
                            Text("Loading insulin history…").foregroundStyle(.secondary)
                        }
                    } else if state.hasSufficientHistory, let tdd = state.averageTDD {
                        HStack {
                            Text("7-Day Average TDD")
                            Spacer()
                            Text("\(formattedRatio(tdd)) U").bold()
                        }
                        Text("Based on \(state.tddSampleDays) days of recorded insulin delivery.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "hourglass").foregroundStyle(.orange)
                            Text(
                                "Not enough insulin history yet — Trio needs at least \(StateModel.minimumSampleDays) days of pump data. Until then, use the body weight estimate."
                            )
                            .font(.footnote)
                        }
                    }
                case .bodyWeight:
                    HStack {
                        Text("Body Weight")
                        TextField("0", value: $weightInput, format: .number)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .onChange(of: weightInput) { _, newValue in
                                updateWeight(newValue, unit: weightUnit)
                            }
                        Picker("", selection: $weightUnit) {
                            ForEach(WeightUnit.allCases) { unit in
                                Text(unit.displayName).tag(unit)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 100)
                        .onChange(of: weightUnit) { _, newUnit in
                            updateWeight(weightInput, unit: newUnit)
                        }
                    }
                    if let tdd = state.effectiveTDD {
                        HStack {
                            Text("Estimated TDD")
                            Spacer()
                            Text("\(formattedRatio(tdd)) U").bold()
                        }
                        Text(
                            "Estimated as \(formattedRatio(StateModel.unitsPerKg)) units per kg of body weight per day — a typical starting total for adults."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .listRowBackground(Color.chart)
        }

        private var recommendationSection: some View {
            Section(
                header: Text("Recommendations").glassCaption()
            ) {
                recommendationRow(
                    title: String(localized: "Insulin Sensitivity (ISF)"),
                    current: currentISFDescription,
                    recommended: "\(formattedISF(state.recommendedISF)) \(isfUnitLabel)",
                    applyAction: { isISFConfirmationPresented = true }
                )

                recommendationRow(
                    title: String(localized: "Carb Ratio (CR)"),
                    current: currentCarbRatioDescription,
                    recommended: "\(formattedRatio(state.recommendedCarbRatio)) g/U",
                    applyAction: { isCarbRatioConfirmationPresented = true }
                )
            }
            .listRowBackground(Color.chart)
        }

        private func recommendationRow(
            title: String,
            current: String,
            recommended: String,
            applyAction: @escaping () -> Void
        ) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                        Text(current)
                    }
                    Spacer()
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("Recommended").font(.caption).foregroundStyle(.secondary)
                        Text(recommended).bold()
                    }
                }
                Button(action: applyAction) {
                    Text("Apply as All-Day Value")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)
            }
            .padding(.vertical, 4)
        }

        private var methodologySection: some View {
            Section(
                header: Text("How This Is Calculated").glassCaption()
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "ISF uses the “1800 rule”: 1800 ÷ TDD = the mg/dL one unit of rapid-acting insulin lowers glucose. For example, with a TDD of 40 U: 1800 ÷ 40 = 45 mg/dL per unit."
                    )
                    Text(
                        "Carb ratio uses the “500 rule”: 500 ÷ TDD = the grams of carbs one unit covers. With a TDD of 40 U: 500 ÷ 40 ≈ 12.5 g per unit."
                    )
                    Text(
                        "If your glucose regularly ends up above the forecast, your ISF or CR may be too weak (numbers set too high). If you trend low after corrections or meals, they may be too strong. Re-run this calculator as your insulin needs settle, and prefer the insulin history source once you have a week of data."
                    )
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Helpers

        private func updateWeight(_ value: Decimal, unit: WeightUnit) {
            switch unit {
            case .kg:
                state.bodyWeightKg = value
            case .lbs:
                state.bodyWeightKg = value * Decimal(string: "0.453592")!
            }
        }

        private var currentISFDescription: String {
            let values = state.currentSensitivities.map(\.sensitivity)
            guard !values.isEmpty else { return String(localized: "Not set") }
            return scheduleDescription(values: values, formatter: formattedISF, unit: isfUnitLabel)
        }

        private var currentCarbRatioDescription: String {
            let values = state.currentCarbRatioSchedule.map(\.ratio)
            guard !values.isEmpty else { return String(localized: "Not set") }
            return scheduleDescription(values: values, formatter: formattedRatio, unit: String(localized: "g/U"))
        }

        private func scheduleDescription(
            values: [Decimal],
            formatter: (Decimal?) -> String,
            unit: String
        ) -> String {
            guard let minValue = values.min(), let maxValue = values.max() else { return String(localized: "Not set") }
            if minValue == maxValue {
                return "\(formatter(minValue)) \(unit)"
            }
            return "\(formatter(minValue))–\(formatter(maxValue)) \(unit)"
        }

        /// Formats an ISF stored in mg/dL for display in the user's glucose units.
        private func formattedISF(_ value: Decimal?) -> String {
            guard let value else { return "--" }
            let displayValue = state.units == .mgdL ? value : value.asMmolL
            return isfFormatter.string(from: displayValue as NSDecimalNumber) ?? "--"
        }

        private func formattedRatio(_ value: Decimal?) -> String {
            guard let value else { return "--" }
            return ratioFormatter.string(from: value as NSDecimalNumber) ?? "--"
        }
    }
}
