import Combine
import SwiftUI

extension TwilioConfig {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var keychain: Keychain!
        @Injected() private var broadcaster: Broadcaster!
        @Injected() var twilioMessaging: TwilioMessagingManager!

        @Published var twilioEnabled = false
        @Published var accountSID: String = ""
        @Published var authToken: String = ""
        @Published var twilioFromNumber: String = ""
        @Published var twilioRecipients: String = ""
        @Published var twilioSendUrgentLow = true
        @Published var twilioSendLow = true
        @Published var twilioSendHigh = false
        @Published var twilioSendLoopFailure = false
        @Published var twilioUrgentLowThreshold: Decimal = 55
        @Published var twilioCooldownMinutes: Decimal = 30

        var units: GlucoseUnits = .mgdL

        override func subscribe() {
            units = settingsManager.settings.units
            broadcaster.register(SettingsObserver.self, observer: self)

            accountSID = keychain.getValue(String.self, forKey: TwilioMessaging.Config.accountSIDKey) ?? ""
            authToken = keychain.getValue(String.self, forKey: TwilioMessaging.Config.authTokenKey) ?? ""

            $accountSID
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.storeSecret(value, forKey: TwilioMessaging.Config.accountSIDKey)
                }
                .store(in: &lifetime)

            $authToken
                .dropFirst()
                .removeDuplicates()
                .sink { [weak self] value in
                    self?.storeSecret(value, forKey: TwilioMessaging.Config.authTokenKey)
                }
                .store(in: &lifetime)

            subscribeSetting(\.twilioEnabled, on: $twilioEnabled) { twilioEnabled = $0 }
            subscribeSetting(\.twilioSendUrgentLow, on: $twilioSendUrgentLow) { twilioSendUrgentLow = $0 }
            subscribeSetting(\.twilioSendLow, on: $twilioSendLow) { twilioSendLow = $0 }
            subscribeSetting(\.twilioSendHigh, on: $twilioSendHigh) { twilioSendHigh = $0 }
            subscribeSetting(\.twilioSendLoopFailure, on: $twilioSendLoopFailure) { twilioSendLoopFailure = $0 }

            subscribeSetting(\.twilioUrgentLowThreshold, on: $twilioUrgentLowThreshold, initial: {
                twilioUrgentLowThreshold = $0
            }, map: {
                max(min($0, 100), 40)
            })

            // Snap to the nearest picker option so imported settings always show a selection.
            subscribeSetting(\.twilioCooldownMinutes, on: $twilioCooldownMinutes, initial: {
                twilioCooldownMinutes = Self.nearestCooldownOption(to: $0)
            }, map: {
                Self.nearestCooldownOption(to: $0)
            })

            // Debounce the free-text fields so settings are not persisted on every keystroke.
            subscribeSetting(
                \.twilioFromNumber,
                on: $twilioFromNumber.debounce(for: .seconds(1), scheduler: RunLoop.main)
            ) { twilioFromNumber = $0 }

            subscribeSetting(
                \.twilioRecipients,
                on: $twilioRecipients.debounce(for: .seconds(1), scheduler: RunLoop.main)
            ) { twilioRecipients = $0 }
        }

        static func nearestCooldownOption(to value: Decimal) -> Decimal {
            TwilioMessaging.Config.cooldownOptions.min {
                abs(Double(truncating: ($0 - value) as NSNumber)) < abs(Double(truncating: ($1 - value) as NSNumber))
            } ?? value
        }

        private func storeSecret(_ value: String, forKey key: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                keychain.removeObject(forKey: key)
            } else {
                keychain.setValue(trimmed, forKey: key)
            }
        }

        var parsedRecipients: [String] {
            CaregiverMessage.recipients(from: twilioRecipients)
        }

        var isConfigured: Bool {
            twilioMessaging.isConfigured
        }

        @MainActor func sendTestMessage() async throws {
            try await twilioMessaging.sendTestMessage()
        }
    }
}

extension TwilioConfig.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
