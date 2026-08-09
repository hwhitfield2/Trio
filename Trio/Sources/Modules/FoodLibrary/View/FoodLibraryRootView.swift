import CoreData
import SwiftUI
import Swinject

extension FoodLibrary {
    struct RootView: BaseView {
        let resolver: Resolver
        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        @FetchRequest(
            entity: FoodItemStored.entity(),
            sortDescriptors: [NSSortDescriptor(key: "normalizedName", ascending: true)]
        ) var foodItems: FetchedResults<FoodItemStored>

        private var macroFormatter: NumberFormatter {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.maximumFractionDigits = 1
            return formatter
        }

        private var filteredItems: [FoodItemStored] {
            let query = FoodOutcomeMath.normalizedName(state.searchText)
            var items = foodItems.filter { item in
                query.isEmpty || (item.normalizedName ?? "").contains(query)
            }
            switch state.sortOrder {
            case .recent:
                items.sort { ($0.lastUsedAt ?? .distantPast) > ($1.lastUsedAt ?? .distantPast) }
            case .frequent:
                items.sort { $0.useCount > $1.useCount }
            case .name:
                items.sort { ($0.normalizedName ?? "") < ($1.normalizedName ?? "") }
            }
            return items
        }

        var body: some View {
            List {
                Section {
                    Picker("Sort", selection: $state.sortOrder) {
                        ForEach(SortOrder.allCases) { order in
                            Text(order.displayName).tag(order)
                        }
                    }
                    .pickerStyle(.segmented)
                }.listRowBackground(Color.chart)

                Section(
                    footer: Text(
                        "Foods are added automatically when you log carbs with a note. Outcome stats summarize your glucose after eating them and are informational only - discuss any changes with your care team."
                    )
                ) {
                    if filteredItems.isEmpty {
                        Text("No foods yet. Log a meal with a note, or import your meal presets.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(filteredItems) { item in
                        NavigationLink(destination: FoodDetailView(item: item, units: state.units)) {
                            foodRow(item)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                state.delete(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }.listRowBackground(Color.chart)
            }
            .searchable(text: $state.searchText)
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Food Library")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await state.importPresets() }
                    } label: {
                        Text("Import Presets")
                    }
                }
            }
            .alert("Presets Imported", isPresented: $state.showImportAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(state.importedCount) new food(s) added from your meal presets.")
            }
        }

        private func macroString(_ item: FoodItemStored) -> String {
            let carbs = macroFormatter.string(from: item.carbs ?? 0) ?? "0"
            let fat = macroFormatter.string(from: item.fat ?? 0) ?? "0"
            let protein = macroFormatter.string(from: item.protein ?? 0) ?? "0"
            return String(localized: "C \(carbs) g · F \(fat) g · P \(protein) g")
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
        }
    }
}
