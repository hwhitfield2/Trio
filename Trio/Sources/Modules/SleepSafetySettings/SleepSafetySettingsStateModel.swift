import Combine
import CoreData
import SwiftUI

extension SleepSafetySettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var sleepSafetyManager: SleepSafetyManager!
        @Injected() var overrideStorage: OverrideStorage!

        @Published var sleepSafetyEnabled = false
        @Published var sleepWindowStartMinutes: Decimal = 1320
        @Published var sleepWindowEndMinutes: Decimal = 420
        @Published var sleepOverridePresetID = ""
        @Published var sleepEscalationRepeatMinutes: Decimal = 10
        @Published var sleepCaregiverEscalationEnabled = false
        @Published var sleepCaregiverEscalationMinutes: Decimal = 20

        @Published var presets: [SleepOverridePresetOption] = []

        var units: GlucoseUnits = .mgdL

        /// The caregiver stage needs the Twilio SMS service to be set up under Services.
        var isTwilioEnabled: Bool {
            settingsManager?.settings.twilioEnabled ?? false
        }

        var isWindowActiveNow: Bool {
            sleepSafetyManager?.isWindowActive ?? false
        }

        override func subscribe() {
            units = settingsManager.settings.units

            subscribeSetting(\.sleepSafetyEnabled, on: $sleepSafetyEnabled) { sleepSafetyEnabled = $0 }
            subscribeSetting(\.sleepWindowStartMinutes, on: $sleepWindowStartMinutes) { sleepWindowStartMinutes = $0 }
            subscribeSetting(\.sleepWindowEndMinutes, on: $sleepWindowEndMinutes) { sleepWindowEndMinutes = $0 }
            subscribeSetting(\.sleepOverridePresetID, on: $sleepOverridePresetID) { sleepOverridePresetID = $0 }
            subscribeSetting(\.sleepEscalationRepeatMinutes, on: $sleepEscalationRepeatMinutes) {
                sleepEscalationRepeatMinutes = $0 }
            subscribeSetting(\.sleepCaregiverEscalationEnabled, on: $sleepCaregiverEscalationEnabled) {
                sleepCaregiverEscalationEnabled = $0 }
            subscribeSetting(\.sleepCaregiverEscalationMinutes, on: $sleepCaregiverEscalationMinutes) {
                sleepCaregiverEscalationMinutes = $0 }

            Task { @MainActor in
                await self.setupPresets()
            }
        }

        /// Loads the existing override presets for the picker (IDs fetched on a background
        /// context, materialized on the view context - same as the Shortcuts integration).
        @MainActor func setupPresets() async {
            do {
                let presetIDs = try await overrideStorage.fetchForOverridePresets()
                let viewContext = CoreDataStack.shared.persistentContainer.viewContext
                let presetObjects = try presetIDs.compactMap { id in
                    try viewContext.existingObject(with: id) as? OverrideStored
                }
                presets = presetObjects.compactMap { object in
                    guard let id = object.id, let name = object.name, !name.isEmpty else { return nil }
                    return SleepOverridePresetOption(id: id, name: name)
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to fetch override presets: \(error)")
            }
        }
    }
}
