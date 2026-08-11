import SwiftUI

/// Text-based food lookup presented from the bolus calculator and the Home carbs
/// drawer: describe what you are eating (restaurant dish, packaged snack, ...),
/// the AI returns the same structured estimate the meal photo flow produces, and
/// accepted values are applied to the meal entry.
struct FoodSearchView: View {
    @Bindable var state: Treatments.StateModel
    /// Called after an accepted result has been applied to the state model, so
    /// non-router presenters (the Home carbs drawer) can sync their local UI.
    var onApplied: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private enum Phase {
        case input
        case searching(String)
        case result(MealPhotoAnalysisResult)
        case failed(String, String)
    }

    @State private var query = ""
    @State private var phase: Phase = .input
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var queryFieldFocused: Bool

    private var isSearching: Bool {
        if case .searching = phase { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") {
                            searchTask?.cancel()
                            dismiss()
                        }
                    }
                }
        }
        .interactiveDismissDisabled(isSearching)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .input:
            inputView
                .navigationTitle("Food Search")

        case let .searching(searchedQuery):
            searchingView(searchedQuery)
                .navigationTitle("Searching")

        case let .result(result):
            FoodSearchResultView(
                result: result,
                showsFatProtein: true,
                onAccept: { adjustedResult in
                    state.applyMealPhotoAnalysis(adjustedResult)
                    onApplied?()
                    dismiss()
                },
                onEditSearch: { phase = .input }
            )
            .navigationTitle("Food Estimate")

        case let .failed(failedQuery, message):
            failedView(failedQuery, message: message)
                .navigationTitle("Search Failed")
        }
    }

    private var inputView: some View {
        ZStack {
            appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()

            VStack(alignment: .leading, spacing: 14) {
                Text("Describe what you are eating. Include the restaurant name and portion details when you can.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                TextField(
                    "e.g. Chipotle chicken burrito bowl with white rice, black beans, and cheese",
                    text: $query,
                    axis: .vertical
                )
                .lineLimit(3 ... 6)
                .padding(12)
                .background(Color.chart)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .focused($queryFieldFocused)
                .submitLabel(.search)
                .onSubmit { startSearch() }

                Button {
                    startSearch()
                } label: {
                    Label("Search", systemImage: "magnifyingglass")
                        .font(.headline)
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                        .background(
                            query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? Color.primary.opacity(0.12)
                                : Color(.systemBlue)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()
            }
            .padding()
        }
        .onAppear { queryFieldFocused = true }
    }

    private func searchingView(_ searchedQuery: String) -> some View {
        ZStack {
            appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 20) {
                Text("“\(searchedQuery)”")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                ProgressView()
                    .controlSize(.large)

                Text("Looking up nutrition information and estimating carbs...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func failedView(_ failedQuery: String, message: String) -> some View {
        ZStack {
            appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)

                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    search(failedQuery)
                } label: {
                    Text("Try Again").frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    phase = .input
                } label: {
                    Text("Edit Search").frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private func startSearch() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        search(trimmed)
    }

    private func search(_ searchQuery: String) {
        phase = .searching(searchQuery)
        searchTask = Task {
            do {
                let result = try await state.searchFood(query: searchQuery)
                guard !Task.isCancelled else { return }
                await MainActor.run { phase = .result(result) }
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { phase = .failed(searchQuery, message) }
            }
        }
    }
}

/// Review screen for a food search result. Mirrors MealPhotoResultView, but with the
/// stated portion assumptions in place of the photo details, and a quantity stepper
/// per item: "McDonald's chicken nuggets" comes back as one 10 pc serving and the
/// user multiplies it to what they actually ordered. Totals recompute locally - no
/// second AI round-trip - and the adjusted values are what gets applied.
struct FoodSearchResultView: View {
    let result: MealPhotoAnalysisResult
    let showsFatProtein: Bool
    let onAccept: (MealPhotoAnalysisResult) -> Void
    let onEditSearch: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    /// Quantity multiplier per component (keyed by component id). 0 = excluded.
    @State private var quantities: [String: Decimal] = [:]

    private static let quantityStep = Decimal(string: "0.5")!
    private static let maxQuantity: Decimal = 10

    private var gramsFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        return formatter
    }

    private var hoursFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private var quantityFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }

    private func grams(_ value: Decimal) -> String {
        (gramsFormatter.string(from: value as NSNumber) ?? "0") + String(localized: " g", comment: "grams unit")
    }

    // MARK: - Quantity adjustment

    private func quantity(for component: MealComponent) -> Decimal {
        quantities[component.id] ?? 1
    }

    private func quantityLabel(for component: MealComponent) -> String {
        "×" + (quantityFormatter.string(from: quantity(for: component) as NSNumber) ?? "1")
    }

    private func scaled(_ component: MealComponent) -> MealComponent {
        let factor = quantity(for: component)
        let portion = factor == 1
            ? component.portionEstimate
            : component.portionEstimate + " " + quantityLabel(for: component)
        return MealComponent(
            name: component.name,
            portionEstimate: portion,
            carbsGrams: component.carbsGrams * factor,
            fatGrams: component.fatGrams * factor,
            proteinGrams: component.proteinGrams * factor,
            confidence: component.confidence
        )
    }

    /// Components with the user's quantities applied; excluded (×0) items dropped.
    private var adjustedComponents: [MealComponent] {
        result.components.filter { quantity(for: $0) > 0 }.map(scaled)
    }

    private var adjustedCarbs: Decimal {
        result.components.isEmpty
            ? result.totalCarbsGrams
            : adjustedComponents.reduce(0) { $0 + $1.carbsGrams }
    }

    private var adjustedFat: Decimal {
        result.components.isEmpty
            ? result.totalFatGrams
            : adjustedComponents.reduce(0) { $0 + $1.fatGrams }
    }

    private var adjustedProtein: Decimal {
        result.components.isEmpty
            ? result.totalProteinGrams
            : adjustedComponents.reduce(0) { $0 + $1.proteinGrams }
    }

    /// The result with quantity adjustments baked into components and totals.
    private var adjustedResult: MealPhotoAnalysisResult {
        MealPhotoAnalysisResult(
            isFood: result.isFood,
            mealName: result.mealName,
            components: adjustedComponents,
            totalCarbsGrams: adjustedCarbs,
            totalFatGrams: adjustedFat,
            totalProteinGrams: adjustedProtein,
            mealSource: result.mealSource,
            mealSourceRationale: result.mealSourceRationale,
            scaleReferenceDetected: result.scaleReferenceDetected,
            scaleReferenceNote: result.scaleReferenceNote,
            absorptionHours: result.absorptionHours,
            absorptionRationale: result.absorptionRationale,
            slowAbsorptionMeal: result.slowAbsorptionMeal,
            overallConfidence: result.overallConfidence,
            warnings: result.warnings
        )
    }

    private func adjustQuantity(for component: MealComponent, by delta: Decimal) {
        let current = quantity(for: component)
        let next = min(max(current + delta, 0), Self.maxQuantity)
        quantities[component.id] = next
    }

    var body: some View {
        List {
            headerSection
            sourceSection
            componentsSection
            absorptionSection
            if !result.warnings.isEmpty {
                warningsSection
            }
            actionSection
        }
        .listSectionSpacing(10)
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text(result.mealName).font(.headline)

                HStack(spacing: 4) {
                    Text("Confidence:")
                    Text(result.overallConfidence.displayName).bold()
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if !result.scaleReferenceNote.isEmpty {
                Text(result.scaleReferenceNote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }.listRowBackground(Color.chart)
    }

    private var sourceSection: some View {
        Section(header: Text("Meal Source")) {
            HStack {
                Image(systemName: result.mealSource.iconName)
                    .foregroundStyle(.blue)
                Text(result.mealSource.displayName).bold()
            }
            Text(result.mealSourceRationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }.listRowBackground(Color.chart)
    }

    private var componentsSection: some View {
        Section {
            ForEach(result.components) { component in
                componentRow(component)
            }

            HStack {
                Text("Total Carbs").bold()
                Spacer()
                Text(grams(adjustedCarbs)).bold()
            }

            if showsFatProtein {
                HStack {
                    Text("Total Fat")
                    Spacer()
                    Text(grams(adjustedFat))
                }
                HStack {
                    Text("Total Protein")
                    Spacer()
                    Text(grams(adjustedProtein))
                }
            }
        } header: {
            Text("Components")
        } footer: {
            Text("Adjust the quantity of each item to match what you ordered. Set an item to ×0 to leave it out.")
        }
        .listRowBackground(Color.chart)
    }

    private func componentRow(_ component: MealComponent) -> some View {
        let factor = quantity(for: component)
        let excluded = factor == 0
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(component.name)
                    .strikethrough(excluded)
                    .foregroundStyle(excluded ? Color.secondary : Color.primary)
                Spacer()
                Text(grams(component.carbsGrams * factor) + String(localized: " carbs"))
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text(component.portionEstimate)
                Spacer()
                if showsFatProtein, !excluded {
                    Text(
                        String(localized: "Fat ") + grams(component.fatGrams * factor)
                            + String(localized: " · Protein ") + grams(component.proteinGrams * factor)
                    )
                }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)

            HStack(spacing: 14) {
                Text("Quantity")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    adjustQuantity(for: component, by: -Self.quantityStep)
                } label: {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(factor > 0 ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .disabled(factor <= 0)

                Text(quantityLabel(for: component))
                    .font(.subheadline.bold())
                    .frame(minWidth: 44)

                Button {
                    adjustQuantity(for: component, by: Self.quantityStep)
                } label: {
                    Image(systemName: "plus.circle")
                        .foregroundStyle(factor < Self.maxQuantity ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .buttonStyle(.borderless)
                .disabled(factor >= Self.maxQuantity)
            }
            .padding(.top, 2)
        }
    }

    private var absorptionSection: some View {
        Section(header: Text("Carb Absorption")) {
            HStack {
                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.blue)
                Text("Estimated Duration")
                Spacer()
                Text(
                    (hoursFormatter.string(from: result.absorptionHours as NSNumber) ?? "0")
                        + String(localized: " hr", comment: "hours unit")
                ).bold()
            }
            if result.slowAbsorptionMeal {
                HStack(spacing: 6) {
                    Image(systemName: "tortoise.fill").foregroundStyle(.orange)
                    Text("Slow-absorbing meal - a reduced initial bolus may be appropriate.")
                        .font(.footnote)
                }
            }
            if result.absorptionHours > BaseCarbsStorage.standardAbsorptionHours {
                Text(
                    "When logged, the carbs will be spread across this duration so the loop's dosing follows the slower absorption."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
            Text(result.absorptionRationale)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }.listRowBackground(Color.chart)
    }

    private var warningsSection: some View {
        Section(header: Text("Check Before Logging")) {
            ForEach(result.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text(warning).font(.footnote)
                }
            }
        }.listRowBackground(Color.chart)
    }

    private var everythingExcluded: Bool {
        !result.components.isEmpty && adjustedComponents.isEmpty
    }

    private var actionSection: some View {
        Section {
            Button {
                onAccept(adjustedResult)
            } label: {
                Text("Use These Values")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 35)
            }
            .listRowBackground(everythingExcluded ? Color.secondary.opacity(0.4) : Color(.systemBlue))
            .disabled(everythingExcluded)

            Button {
                onEditSearch()
            } label: {
                Text("Edit Search")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.chart)
        } footer: {
            Text(
                "AI estimates can be wrong. Portions at restaurants vary - always review the values and adjust them to what is actually served before bolusing."
            )
            .font(.footnote)
        }
    }
}
