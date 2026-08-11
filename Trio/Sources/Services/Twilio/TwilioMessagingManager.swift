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
        static let cooldownOptions: [Decimal] = [5, 10, 15, 30, 60, 120, 240]
    }
}

enum TwilioMessagingError: LocalizedError {
    case missingCredentials
    case missingRecipients
    case badStatusCode(Int, String?)
    case invalidResponse
    case recipientFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return String(
                localized: "Twilio is not fully configured. Enter the Account SID, Auth Token and sending phone number."
            )
        case .missingRecipients:
            return String(localized: "No destination phone numbers are configured for Twilio messages.")
        case let .recipientFailed(recipient, reason):
            return String(localized: "Sending to \(recipient) failed: \(reason)")
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
    /// Sends a sleep-safety escalation SMS to all configured recipients. This is an
    /// explicit, once-per-episode escalation, so it bypasses the alert cooldown policy.
    @MainActor func sendSleepEscalationMessage(_ body: String) async throws
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
    private let queue = DispatchQueue(label: "BaseTwilioMessagingManager.queue", qos: .utility)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()
        subscribeToGlucoseUpdates()
    }

    private func subscribeToGlucoseUpdates() {
        // updatePublisher only fires for batch inserts (e.g. backfills), not for the single
        // readings a live CGM delivers, so additionally observe GlucoseStored Core Data saves —
        // same workaround as GarminManager.
        glucoseStorage.updatePublisher
            .sink { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    await self.evaluateAndSendIfNeeded()
                }
            }
            .store(in: &subscriptions)

        coreDataPublisher?
            .filteredByEntityName("GlucoseStored")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
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
        let failures = try await send(body: body, to: recipients)
        if let failure = failures.first {
            throw TwilioMessagingError.recipientFailed(failure.recipient, failure.error.localizedDescription)
        }
    }

    @MainActor func sendSleepEscalationMessage(_ body: String) async throws {
        let recipients = CaregiverMessage.recipients(from: settingsManager.settings.twilioRecipients)
        guard !recipients.isEmpty else { throw TwilioMessagingError.missingRecipients }

        let failures = try await send(body: body, to: recipients)
        for failure in failures {
            warning(.service, "Sleep safety SMS to \(failure.recipient) failed", error: failure.error)
        }
    }

    @MainActor private func evaluateAndSendIfNeeded() async {
        let settings = settingsManager.settings
        guard settings.twilioEnabled, isConfigured else {
            // Reset the episode marker so re-enabling starts fresh instead of suppressing
            // an alert that never resolved while the feature was off.
            if !activeAlertKindRaw.isEmpty { activeAlertKindRaw = "" }
            return
        }

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
            let failures = try await send(body: messageBody(for: kind), to: recipients)
            // At least one recipient was reached, so record the send: retrying the failed
            // numbers every cycle would flood the reachable ones with duplicates.
            lastSentDate = Date()
            activeAlertKindRaw = kind.rawValue
            debug(
                .service,
                "Twilio alert sent (\(kind.rawValue)) to \(recipients.count - failures.count)/\(recipients.count) recipient(s)"
            )
            for failure in failures {
                warning(.service, "Twilio alert to \(failure.recipient) failed", error: failure.error)
            }
        } catch {
            // Nothing was delivered; state stays untouched so the next glucose update retries.
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
        case .high,
             .low:
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

    /// Sends the message to every recipient, collecting per-recipient failures. Throws only when
    /// the configuration is unusable or no recipient could be reached — one bad number must not
    /// block delivery to (or trigger endless re-sends for) the others.
    @discardableResult private func send(
        body: String,
        to recipients: [String]
    ) async throws -> [(recipient: String, error: Error)] {
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

        var failures: [(recipient: String, error: Error)] = []

        for recipient in recipients {
            do {
                try await sendSingle(
                    accountSID: accountSID,
                    authToken: authToken,
                    from: fromNumber,
                    to: recipient,
                    body: body
                )
            } catch {
                failures.append((recipient: recipient, error: error))
            }
        }

        if failures.count == recipients.count, let first = failures.first {
            throw first.error
        }

        return failures
    }

    private func sendSingle(accountSID: String, authToken: String, from: String, to: String, body: String) async throws {
        guard let request = TwilioRequestBuilder.request(
            accountSID: accountSID,
            authToken: authToken,
            from: from,
            to: to,
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

private struct TwilioErrorResponse: Decodable {
    let code: Int?
    let message: String?
}
