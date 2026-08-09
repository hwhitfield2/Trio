import CoreData
import SwiftUI

/// Sheet presented from the Treatments screen: pick a food from the personal library
/// to add its macros to the pending carb entry. Adding never replaces what the user
/// already typed - macros accumulate, like meal presets.
struct FoodPickerView: View {
    @Bindable var state: Treatments.StateModel

    @Environment(\.colorScheme) var colorScheme
    @Environment(\.dismiss) var dismiss
    @Environment(AppState.self) var appState

    @State private var searchText = ""

    @FetchRequest(
        entity: FoodItemStored.entity(),
        sortDescriptors: [NSSortDescriptor(key: "lastUsedAt", ascending: false)]
    ) var foodItems: FetchedResults<FoodItemStored>

    private var macroFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var filteredItems: [FoodItemStored] {
        let query = FoodOutcomeMath.normalizedName(searchText)
        guard !query.isEmpty else { return Array(foodItems) }
        return foodItems.filter { ($0.normalizedName ?? "").contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if filteredItems.isEmpty {
                        Text("No foods yet. Log a meal with a note and it will appear here.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredItems) { item in
                        Button {
                            apply(item)
                        } label: {
                            foodRow(item)
                        }
                        .buttonStyle(.plain)
                    }
                }.listRowBackground(Color.chart)
            }
            .searchable(text: $searchText)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .navigationTitle("Food Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("Close")
                    }
                }
            }
        }
    }

    private func apply(_ item: FoodItemStored) {
        state.carbs += ((item.carbs ?? 0) as NSDecimalNumber) as Decimal
        state.fat += ((item.fat ?? 0) as NSDecimalNumber) as Decimal
        state.protein += ((item.protein ?? 0) as NSDecimalNumber) as Decimal
        if let name = item.name {
            if state.note.isEmpty {
                state.note = String(name.prefix(25))
            }
            state.summation.append(name)
        }
        dismiss()
    }

    @ViewBuilder private func foodRow(_ item: FoodItemStored) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.name ?? String(localized: "Unnamed"))
                    .font(.headline)
                Spacer()
                if item.useCount > 0 {
                    Text("×\(item.useCount)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Text(macroString(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let lastUsed = item.lastUsedAt {
                    Text(lastUsed.formatted(date: .abbreviated, time: .omitted))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func macroString(_ item: FoodItemStored) -> String {
        let carbs = macroFormatter.string(from: item.carbs ?? 0) ?? "0"
        let fat = macroFormatter.string(from: item.fat ?? 0) ?? "0"
        let protein = macroFormatter.string(from: item.protein ?? 0) ?? "0"
        return String(localized: "C \(carbs) g · F \(fat) g · P \(protein) g")
    }
}
