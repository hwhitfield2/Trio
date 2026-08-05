import Combine
import CoreData
import Foundation
import Swinject

enum TwilioMessaging {
    enum Config {
        static let accountSIDKey = "TwilioMessaging.accountSID"
        static let authTokenKey = "TwilioMessaging.authToken"
        static let timeout: TimeInterval = 30
        static let loopFailureGraceMinutes: Double = 45
    }
}

enum TwilioMessagingError: LocalizedError {
    case missingCredentials
    case missingRecipients
    case badStatusCode(Int, String?)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(
                localized: "Twilio is not fully configured. Enter the Account SID, Auth Token and sending phone number."
            )
        case .missingRecipients:
            return String(localized: "No destination phone numbers are configured for Twilio messages.")
        case let .badStatusCode(code, message):
            if let message = message, !message.isEmpty {
                return String(localized: "Twilio returned an error (\(code)): \(message)")
            }
            return String(localized: "Twilio returned an error (\(code)). Please check your configuration.")
        case .invalidResponse:
            return String(localized: "Twilio returned an unexpected response. Please try again.")
        }
    }
}

/// Sends caregiver SMS alerts through the Twilio REST API when user-defined conditions are met.
///
/// Unlike iMessage, an HTTPS API can deliver messages with no user interaction, so this service
/// runs unattended: it observes glucose updates and texts the configured numbers on urgent lows,
/// lows, highs or a stalled loop — throttled by a cooldown and de-duplicated per alert episode.
protocol TwilioMessagingManager {
    /// Whether credentials and a sending number are stored.
    var isConfigured: Bool { get }
    /// Sends a test SMS to all configured recipients to verify the setup.
    @MainActor func sendTestMessage() async throws
}

final class BaseTwilioMessagingManager: TwilioMessagingManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var keychain: Keychain!
    @Injected() private var caregiverMessaging: CaregiverMessagingManager!

    @Persisted(key: "TwilioMessaging.lastSentDate") private var lastSentDate: Date = .distantPast
    @Persisted(key: "TwilioMessaging.activeAlertKind") private var activeAlertKindRaw: String = ""

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        subscribeToGlucoseUpdates()
    }

    private func subscribeToGlucoseUpdates() {
        glucoseStorage.updatePublisher
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.evaluateAndSendIfNeeded()
                }
            }
            .store(in: &subscriptions)
    }

    var isConfigured: Bool {
        guard let accountSID = keychain.getValue(String.self, forKey: TwilioMessaging.Config.accountSIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let authToken = keychain.getValue(String.self, forKey: TwilioMessaging.Config.authTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else { return false }
        let fromNumber = settingsManager.settings.twilioFromNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        return !accountSID.isEmpty && !authToken.isEmpty && !fromNumber.isEmpty
    }

    @MainActor func sendTestMessage() async throws {
        let recipients = CaregiverMessage.recipients(from: settingsManager.settings.twilioRecipients)
        guard !recipients.isEmpty else { throw TwilioMessagingError.missingRecipients }

        let body = String(
            localized: "Trio test message: Twilio SMS alerts are configured correctly.",
            comment: "Twilio test SMS body"
        ) + " " + caregiverMessaging.statusMessage()
        try await send(body: body, to: recipients)
    }

    @MainActor private func evaluateAndSendIfNeeded() async {
        let settings = settingsManager.settings
        guard settings.twilioEnabled, isConfigured else { return }

        let recipients = CaregiverMessage.recipients(from: settings.twilioRecipients)
        guard !recipients.isEmpty else { return }

        let conditions = TwilioAlertPolicy.Conditions(
            sendUrgentLow: settings.twilioSendUrgentLow,
            sendLow: settings.twilioSendLow,
            sendHigh: settings.twilioSendHigh,
            sendLoopFailure: settings.twilioSendLoopFailure,
            urgentLowThreshold: settings.twilioUrgentLowThreshold,
            lowThreshold: settings.lowGlucose,
            highThreshold: settings.highGlucose,
            loopFailureGraceMinutes: TwilioMessaging.Config.loopFailureGraceMinutes,
            cooldownMinutes: Double(truncating: settings.twilioCooldownMinutes as NSNumber)
        )

        let state = TwilioAlertPolicy.State(
            glucose: latestGlucoseValue(),
            lastLoopDate: apsManager.lastLoopDate,
            lastSentDate: lastSentDate == .distantPast ? nil : lastSentDate,
            activeAlertKind: TwilioAlertKind(rawValue: activeAlertKindRaw),
            now: Date()
        )

        // When no condition is met anymore, clear the active alert so its next occurrence sends again.
        guard TwilioAlertPolicy.currentKind(conditions: conditions, state: state) != nil else {
            activeAlertKindRaw = ""
            return
        }

        guard let kind = TwilioAlertPolicy.evaluate(conditions: conditions, state: state) else { return }

        do {
            try await send(body: messageBody(for: kind), to: recipients)
            lastSentDate = Date()
            activeAlertKindRaw = kind.rawValue
            debug(.service, "Twilio alert sent (\(kind.rawValue)) to \(recipients.count) recipient(s)")
        } catch {
            warning(.service, "Twilio alert failed to send", error: error)
        }
    }

    @MainActor private func latestGlucoseValue() -> Int? {
        do {
            let readings = try CoreDataStack.shared.fetchEntities(
                ofType: GlucoseStored.self,
                onContext: viewContext,
                predicate: NSPredicate.predicateFor30MinAgo,
                key: "date",
                ascending: false,
                fetchLimit: 1
            ) as? [GlucoseStored] ?? []
            return readings.first.map { Int($0.glucose) }
        } catch {
            warning(.service, "Twilio alert evaluation could not fetch glucose", error: error)
            return nil
        }
    }

    @MainActor private func messageBody(for kind: TwilioAlertKind) -> String {
        let status = caregiverMessaging.statusMessage()
        switch kind {
        case .urgentLow:
            return String(localized: "URGENT —", comment: "Twilio urgent low SMS prefix") + " " + status
        case .low,
             .high:
            return status
        case .loopFailure:
            return String(
                format: String(
                    localized: "Trio alert: no completed loop for over %d minutes.",
                    comment: "Twilio loop failure SMS lead"
                ),
                Int(TwilioMessaging.Config.loopFailureGraceMinutes)
            ) + " " + status
        }
    }

    private func send(body: String, to recipients: [String]) async throws {
        guard let accountSID = keychain.getValue(String.self, forKey: TwilioMessaging.Config.accountSIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let authToken = keychain.getValue(String.self, forKey: TwilioMessaging.Config.authTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !accountSID.isEmpty, !authToken.isEmpty
        else {
            throw TwilioMessagingError.missingCredentials
        }

        let fromNumber = settingsManager.settings.twilioFromNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromNumber.isEmpty else { throw TwilioMessagingError.missingCredentials }

        for recipient in recipients {
            guard let request = TwilioRequestBuilder.request(
                accountSID: accountSID,
                authToken: authToken,
                from: fromNumber,
                to: recipient,
                body: body,
                timeout: TwilioMessaging.Config.timeout
            ) else {
                throw TwilioMessagingError.invalidResponse
            }

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw TwilioMessagingError.invalidResponse
            }

            guard 200 ..< 300 ~= http.statusCode else {
                let apiError = try? JSONDecoder().decode(TwilioErrorResponse.self, from: data)
                throw TwilioMessagingError.badStatusCode(http.statusCode, apiError?.message)
            }
        }
    }
}

private struct TwilioErrorResponse: Decodable {
    let code: Int?
    let message: String?
}
