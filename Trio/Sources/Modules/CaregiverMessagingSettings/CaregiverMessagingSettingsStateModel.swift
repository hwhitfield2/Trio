import Combine
import SwiftUI

extension CaregiverMessagingSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var caregiverMessaging: CaregiverMessagingManager!

        @Published var caregiverMessagingEnabled = false
        @Published var caregiverRecipients = ""
        @Published var caregiverMessagesIncludeIOBCOB = true
        @Published var caregiverAlertQuickAction = true

        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            units = settingsManager.settings.units

            subscribeSetting(\.caregiverMessagingEnabled, on: $caregiverMessagingEnabled) { caregiverMessagingEnabled = $0 }
            subscribeSetting(\.caregiverMessagesIncludeIOBCOB, on: $caregiverMessagesIncludeIOBCOB) {
                caregiverMessagesIncludeIOBCOB = $0 }
            subscribeSetting(\.caregiverAlertQuickAction, on: $caregiverAlertQuickAction) { caregiverAlertQuickAction = $0 }

            // Debounce the free-text recipients field so settings are not persisted on every keystroke.
            subscribeSetting(
                \.caregiverRecipients,
                on: $caregiverRecipients.debounce(for: .seconds(1), scheduler: RunLoop.main)
            ) { caregiverRecipients = $0 }
        }

        var parsedRecipients: [String] {
            CaregiverMessage.recipients(from: caregiverRecipients)
        }

        @MainActor func composeStatusMessage() -> String {
            caregiverMessaging.statusMessage()
        }
    }
}
