import AppIntents
import Foundation

/// Returns the caregiver status text so a Shortcuts automation can pass it to the built-in
/// "Send Message" action. This is the Apple-sanctioned way to send iMessages on the user's
/// behalf without interaction: personal automations in the Shortcuts app can run the
/// "Send Message" action unattended.
@available(iOS 16.0, *) struct CaregiverMessageIntent: AppIntent {
    // Title of the action in the Shortcuts app
    static var title: LocalizedStringResource = "Get Caregiver Update"

    // Description of the action in the Shortcuts app
    static var description = IntentDescription(
        "Composes a caregiver-friendly status text with the latest glucose reading, trend, IOB and COB from Trio. Combine it with the 'Send Message' action in a Shortcuts automation to deliver updates via iMessage automatically."
    )

    static var parameterSummary: some ParameterSummary {
        Summary("Get a caregiver status update from Trio")
    }

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let intentRequest = CaregiverMessageIntentRequest()
        return try .result(value: intentRequest.statusMessage())
    }
}

@available(iOS 16.0, *) final class CaregiverMessageIntentRequest: BaseIntentsRequest {
    @Injected() var caregiverMessaging: CaregiverMessagingManager!

    enum CaregiverMessageIntentError: LocalizedError {
        case disabled

        var errorDescription: String? {
            String(
                localized: "Caregiver Messaging is disabled. Enable it in Trio under Settings > Notifications > Caregiver Messaging."
            )
        }
    }

    @MainActor func statusMessage() throws -> String {
        guard settingsManager.settings.caregiverMessagingEnabled else {
            throw CaregiverMessageIntentError.disabled
        }
        return caregiverMessaging.statusMessage()
    }
}
