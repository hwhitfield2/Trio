import SwiftUI

/// Review screen for an AI meal-photo analysis.
///
/// Shows the identified components, macro totals, the homemade/restaurant judgement,
/// and the absorption estimate. Nothing is logged until the user accepts the values.
struct MealPhotoResultView: View {
    let image: UIImage
    let result: MealPhotoAnalysisResult
    let showsFatProtein: Bool
    let onAccept: () -> Void
    let onRetake: () -> Void

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

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

    private func grams(_ value: Decimal) -> String {
        (gramsFormatter.string(from: value as NSNumber) ?? "0") + String(localized: " g", comment: "grams unit")
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
            HStack(alignment: .top, spacing: 12) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 84, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 6) {
                    Text(result.mealName).font(.headline)

                    HStack(spacing: 4) {
                        Image(systemName: result.scaleReferenceDetected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.scaleReferenceDetected ? .green : .orange)
                        Text(
                            result.scaleReferenceDetected
                                ? String(localized: "Scale reference found")
                                : String(localized: "No scale reference found")
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 4) {
                        Text("Confidence:")
                        Text(result.overallConfidence.displayName).bold()
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if !result.scaleReferenceDetected, !result.scaleReferenceNote.isEmpty {
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
        Section(header: Text("Components")) {
            ForEach(result.components) { component in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(component.name)
                        Spacer()
                        Text(grams(component.carbsGrams) + String(localized: " carbs"))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(component.portionEstimate)
                        Spacer()
                        if showsFatProtein {
                            Text(
                                String(localized: "Fat ") + grams(component.fatGrams)
                                    + String(localized: " · Protein ") + grams(component.proteinGrams)
                            )
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("Total Carbs").bold()
                Spacer()
                Text(grams(result.totalCarbsGrams)).bold()
            }

            if showsFatProtein {
                HStack {
                    Text("Total Fat")
                    Spacer()
                    Text(grams(result.totalFatGrams))
                }
                HStack {
                    Text("Total Protein")
                    Spacer()
                    Text(grams(result.totalProteinGrams))
                }
            }
        }.listRowBackground(Color.chart)
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

    private var actionSection: some View {
        Section {
            Button {
                onAccept()
            } label: {
                Text("Use These Values")
                    .font(.headline)
                    .foregroundStyle(Color.white)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .frame(height: 35)
            }
            .listRowBackground(Color(.systemBlue))

            Button {
                onRetake()
            } label: {
                Text("Retake Photo")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .listRowBackground(Color.chart)
        } footer: {
            Text(
                "AI estimates can be wrong. Always review the values and adjust them to your own knowledge of the meal before bolusing."
            )
            .font(.footnote)
        }
    }
}
