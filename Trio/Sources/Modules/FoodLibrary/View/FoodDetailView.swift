import CoreData
import SwiftUI

/// Detail screen for one library food: macros, neutral post-meal outcome stats,
/// and the usage history. Advisory text is informational only - it never suggests doses.
struct FoodDetailView: View {
    @ObservedObject var item: FoodItemStored
    let units: GlucoseUnits

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private var macroFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var sortedUsages: [FoodUsageStored] {
        (item.usages ?? []).sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// Usages with a fully computed, non-degenerate outcome (a start reading existed).
    private var computedUsages: [FoodUsageStored] {
        sortedUsages.filter { $0.outcomeComputed && $0.startGlucose > 0 }
    }

    private var medianPeakDelta: Int? {
        let deltas = computedUsages.map { Int($0.peakDelta) }.sorted()
        guard !deltas.isEmpty else { return nil }
        return deltas[deltas.count / 2]
    }

    private var aboveRangeCount: Int {
        computedUsages.filter(\.endedAboveRange).count
    }

    private var hypoCount: Int {
        computedUsages.filter(\.hypoWithin4h).count
    }

    /// Neutral advisory shown when at least 3 computed usages exist and at least
    /// two thirds share the same pattern. Never shown in the entry flow.
    private var advisoryText: String? {
        let total = computedUsages.count
        guard total >= 3 else { return nil }
        if aboveRangeCount * 3 >= total * 2 {
            return String(
                localized: "You've ended above range after most logged meals of this food. Consider reviewing how you count it with your care team."
            )
        }
        if hypoCount * 3 >= total * 2 {
            return String(
                localized: "You've gone low within 4 hours after most logged meals of this food. Consider reviewing how you count it with your care team."
            )
        }
        return nil
    }

    var body: some View {
        List {
            Section(header: Text("Nutrition")) {
                macroRow(label: String(localized: "Carbs"), value: item.carbs)
                macroRow(label: String(localized: "Fat"), value: item.fat)
                macroRow(label: String(localized: "Protein"), value: item.protein)
                HStack {
                    Text("Times Logged")
                    Spacer()
                    Text("\(item.useCount)")
                        .foregroundStyle(.secondary)
                }
            }.listRowBackground(Color.chart)

            if !computedUsages.isEmpty {
                Section(
                    header: Text("After-Meal Glucose"),
                    footer: Text(advisoryText ?? "")
                ) {
                    if let medianPeakDelta = medianPeakDelta {
                        HStack {
                            Text("Median 2h Rise")
                            Spacer()
                            Text((medianPeakDelta >= 0 ? "+" : "") + medianPeakDelta.formatted(withUnits: units))
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Text("Ended Above Range")
                        Spacer()
                        Text("\(aboveRangeCount) of \(computedUsages.count)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Low Within 4h")
                        Spacer()
                        Text("\(hypoCount) of \(computedUsages.count)")
                            .foregroundStyle(.secondary)
                    }
                }.listRowBackground(Color.chart)
            }

            if !sortedUsages.isEmpty {
                Section(header: Text("History")) {
                    ForEach(sortedUsages) { usage in
                        usageRow(usage)
                    }
                }.listRowBackground(Color.chart)
            }
        }
        .listSectionSpacing(sectionSpacing)
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationBarTitle(item.name ?? String(localized: "Food"))
        .navigationBarTitleDisplayMode(.automatic)
    }

    @ViewBuilder private func macroRow(label: String, value: NSDecimalNumber?) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text((macroFormatter.string(from: value ?? 0) ?? "0") + " g")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func usageRow(_ usage: FoodUsageStored) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if let date = usage.date {
                    Text(date.formatted(date: .abbreviated, time: .shortened))
                        .font(.subheadline)
                }
                Spacer()
                if usage.outcomeComputed, usage.startGlucose > 0 {
                    if usage.endedAboveRange {
                        Image(systemName: "arrow.up.circle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityLabel("Ended above range")
                    }
                    if usage.hypoWithin4h {
                        Image(systemName: "arrow.down.circle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("Low within 4 hours")
                    }
                } else if usage.outcomeComputed {
                    Text("No data")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pending")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if usage.outcomeComputed, usage.startGlucose > 0 {
                let sign = usage.peakDelta >= 0 ? "+" : ""
                Text(
                    "\(Int(usage.startGlucose).formatted(for: units)) → \(sign)\(Int(usage.peakDelta).formatted(for: units)) peak"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}
