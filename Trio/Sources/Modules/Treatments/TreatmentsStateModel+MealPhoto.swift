import Foundation
import UIKit

extension Treatments.StateModel {
    /// Runs the AI analysis for a captured meal photo.
    func analyzeMealPhoto(
        _ image: UIImage,
        scaleReference: ScaleReferenceObject
    ) async throws -> MealPhotoAnalysisResult {
        debug(.bolusState, "Meal photo analysis started (reference: \(scaleReference.rawValue))")
        let result = try await mealPhotoAnalysisManager.analyzeMealPhoto(image, scaleReference: scaleReference)
        debug(
            .bolusState,
            "Meal photo analysis finished: \(result.mealName), carbs \(result.totalCarbsGrams) g, source \(result.mealSource.rawValue)"
        )
        return result
    }

    /// Runs the AI food search for a free-text description (e.g. a restaurant dish).
    func searchFood(query: String) async throws -> MealPhotoAnalysisResult {
        debug(.bolusState, "Food search started")
        let result = try await foodSearchManager.searchFood(query: query)
        debug(
            .bolusState,
            "Food search finished: \(result.mealName), carbs \(result.totalCarbsGrams) g, source \(result.mealSource.rawValue)"
        )
        return result
    }

    /// Applies an accepted analysis to the meal entry fields and recalculates the recommendation.
    ///
    /// Values are clamped to the configured per-entry limits. Fat and protein are
    /// always applied - storage converts them into delayed carb equivalents (FPUs)
    /// so they factor into oref's decisions. The absorption estimate is kept so a
    /// slow meal's carbs are spread across the estimated duration on save. Nothing
    /// is logged until the user taps the regular treatment button.
    @MainActor func applyMealPhotoAnalysis(_ result: MealPhotoAnalysisResult) {
        carbs = min(max(result.totalCarbsGrams.rounded(), 0), maxCarbs)
        fat = min(max(result.totalFatGrams.rounded(), 0), maxFat)
        protein = min(max(result.totalProteinGrams.rounded(), 0), maxProtein)

        mealAbsorptionHours = result.absorptionHours > 0 ? result.absorptionHours : nil

        // The note field is capped at 25 characters in the UI.
        note = String(result.mealName.prefix(25))

        // A slow-absorbing (high fat/protein) meal is the exact case the
        // Reduced Bolus factor exists for - preselect it when available.
        if result.slowAbsorptionMeal, fattyMeals {
            useFattyMealCorrectionFactor = true
            useSuperBolus = false
        }

        Task {
            await updateForecasts()
            insulinCalculated = await calculateInsulin()
        }
    }
}

private extension Decimal {
    func rounded() -> Decimal {
        var value = self
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, .plain)
        return result
    }
}
