import Combine
import SwiftUI

extension MealSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!

        @Published var units: GlucoseUnits = .mgdL
        @Published var useFPUconversion: Bool = false
        @Published var maxCarbs: Decimal = 250
        @Published var maxFat: Decimal = 250
        @Published var maxProtein: Decimal = 250
        @Published var individualAdjustmentFactor: Decimal = 0.5
        @Published var minuteInterval: Decimal = 30
        @Published var delay: Decimal = 60
        @Published var maxMealAbsorptionTime: Decimal = 6
        @Published var mealPhotoAnalysisEnabled: Bool = false
        @Published var mealPhotoApiKey: String = ""
        @Published var unannouncedMealDetectionEnabled: Bool = true

        /// Selected model for meal photo analysis; empty string = app default.
        @Published var mealAnalysisModelId: String = ""
        /// Selected model for text food search; empty string = fast app default.
        @Published var foodSearchModelId: String = ""
        /// Models offered by the provider for the configured API key.
        @Published var availableModels: [AnthropicModelInfo] = []
        @Published var isLoadingModels: Bool = false
        @Published var modelsLoadError: String?

        override func subscribe() {
            units = settingsManager.settings.units

            mealPhotoApiKey = keychain.getValue(String.self, forKey: MealPhotoAnalysis.Config.apiKeyKey) ?? ""

            $mealPhotoApiKey
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] key in
                    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.isEmpty {
                        self?.keychain.removeObject(forKey: MealPhotoAnalysis.Config.apiKeyKey)
                    } else {
                        self?.keychain.setValue(trimmed, forKey: MealPhotoAnalysis.Config.apiKeyKey)
                    }
                }
                .store(in: &lifetime)

            subscribeSetting(\.mealPhotoAnalysisEnabled, on: $mealPhotoAnalysisEnabled) { mealPhotoAnalysisEnabled = $0 }

            subscribeSetting(\.mealAnalysisModelId, on: $mealAnalysisModelId) { mealAnalysisModelId = $0 }

            subscribeSetting(\.foodSearchModelId, on: $foodSearchModelId) { foodSearchModelId = $0 }

            subscribeSetting(
                \.unannouncedMealDetectionEnabled,
                on: $unannouncedMealDetectionEnabled
            ) { unannouncedMealDetectionEnabled = $0 }

            subscribeSetting(\.maxCarbs, on: $maxCarbs) { maxCarbs = $0 }
            subscribeSetting(\.maxFat, on: $maxFat) { maxFat = $0 }
            subscribeSetting(\.maxProtein, on: $maxProtein) { maxProtein = $0 }

            subscribePreferencesSetting(\.maxMealAbsorptionTime, on: $maxMealAbsorptionTime) { maxMealAbsorptionTime = $0 }

            subscribeSetting(\.useFPUconversion, on: $useFPUconversion) { useFPUconversion = $0 }

            // "Fat and Protein Delay"
            subscribeSetting(\.delay, on: $delay) { delay = $0 }

            // "Spread Interval"
            subscribeSetting(\.minuteInterval, on: $minuteInterval) { minuteInterval = $0 }

            // "Fat and Protein Percentage"
            subscribeSetting(\.individualAdjustmentFactor, on: $individualAdjustmentFactor) { individualAdjustmentFactor = $0 }
        }

        /// Fetches the models the configured API key can use, for the model picker.
        /// The current selection is kept in the list even if the provider no longer
        /// returns it, so the picker cannot silently change a stored choice.
        @MainActor func loadAvailableModels() async {
            let apiKey = mealPhotoApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !apiKey.isEmpty, !isLoadingModels else { return }

            isLoadingModels = true
            modelsLoadError = nil
            defer { isLoadingModels = false }

            do {
                var models = try await AnthropicModelsAPI.listModels(apiKey: apiKey)
                let selections = [mealAnalysisModelId, foodSearchModelId]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                for selected in selections where !selected.isEmpty && !models.contains(where: { $0.id == selected }) {
                    models.append(AnthropicModelInfo(id: selected, displayName: selected))
                }
                availableModels = models
            } catch {
                modelsLoadError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
    }
}

extension MealSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
