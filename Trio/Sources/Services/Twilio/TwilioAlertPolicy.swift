import Foundation

enum TwilioAlertKind: String, Codable, CaseIterable {
    case urgentLow
    case low
    case high
    case loopFailure
}

/// Pure decision logic for when a Twilio SMS should go out. Kept free of dependencies so it is unit-testable.
enum TwilioAlertPolicy {
    struct Conditions {
        var sendUrgentLow: Bool = true
        var sendLow: Bool = true
        var sendHigh: Bool = false
        var sendLoopFailure: Bool = false
        /// Thresholds in mg/dL, matching how glucose limits are stored in `TrioSettings`.
        var urgentLowThreshold: Decimal = 55
        var lowThreshold: Decimal = 72
        var highThreshold: Decimal = 270
        var loopFailureGraceMinutes: Double = 45
        var cooldownMinutes: Double = 30
    }

    struct State {
        var glucose: Int?
        var lastLoopDate: Date?
        var lastSentDate: Date?
        /// Alert kind that was already messaged and has not resolved yet.
        var activeAlertKind: TwilioAlertKind?
        var now: Date
    }

    /// The condition currently met, by priority: urgent low > low > high > loop failure.
    /// `nil` means no condition is met, i.e. any previously active alert has resolved.
    static func currentKind(conditions: Conditions, state: State) -> TwilioAlertKind? {
        if let glucose = state.glucose {
            let value = Decimal(glucose)
            if conditions.sendUrgentLow, value <= conditions.urgentLowThreshold { return .urgentLow }
            if conditions.sendLow, value <= conditions.lowThreshold { return .low }
            if conditions.sendHigh, value >= conditions.highThreshold { return .high }
        }
        if conditions.sendLoopFailure, let lastLoop = state.lastLoopDate,
           state.now.timeIntervalSince(lastLoop) > conditions.loopFailureGraceMinutes * 60
        {
            return .loopFailure
        }
        return nil
    }

    /// Decides whether a message should be sent right now.
    /// - The same alert is never re-sent while it is still active.
    /// - A global cooldown throttles consecutive messages, except an escalation to urgent low,
    ///   which always goes through.
    static func evaluate(conditions: Conditions, state: State) -> TwilioAlertKind? {
        guard let kind = currentKind(conditions: conditions, state: state) else { return nil }

        if kind == state.activeAlertKind { return nil }

        if kind != .urgentLow,
           let lastSent = state.lastSentDate,
           state.now.timeIntervalSince(lastSent) < conditions.cooldownMinutes * 60
        {
            return nil
        }

        return kind
    }
}

/// Builds the Twilio REST API request. Pure and unit-testable.
enum TwilioRequestBuilder {
    static func request(
        accountSID: String,
        authToken: String,
        from: String,
        to: String,
        body: String,
        timeout: TimeInterval = 30
    ) -> URLRequest? {
        guard let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(accountSID)/Messages.json")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        let credentials = Data("\(accountSID):\(authToken)".utf8).base64EncodedString()
        request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = formEncoded([("To", to), ("From", from), ("Body", body)]).data(using: .utf8)
        return request
    }

    static func formEncoded(_ pairs: [(String, String)]) -> String {
        pairs.map { "\($0.0)=\(percentEncoded($0.1))" }.joined(separator: "&")
    }

    static func percentEncoded(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }
}
