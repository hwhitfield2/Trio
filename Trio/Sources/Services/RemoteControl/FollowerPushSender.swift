import Foundation
import Security

/// Parsed Firebase service-account credential, used to push status snapshots
/// to Android followers through FCM.
struct FCMServiceAccount {
    let projectId: String
    let clientEmail: String
    let privateKeyPEM: String

    init?(json: String) {
        guard !json.isEmpty,
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projectId = object["project_id"] as? String,
              let clientEmail = object["client_email"] as? String,
              let privateKey = object["private_key"] as? String,
              !projectId.isEmpty, !clientEmail.isEmpty, !privateKey.isEmpty
        else {
            return nil
        }
        self.projectId = projectId
        self.clientEmail = clientEmail
        privateKeyPEM = privateKey
    }
}

enum FollowerPushError: Error {
    case notRegistered
    case missingAPNSCredentials
    case missingFCMCredentials
    case invalidServiceAccountKey
    case transportFailure(String)
}

/// Delivers encrypted payloads to follower devices: APNS for iOS followers
/// (reusing the host's .p8 key) and FCM HTTP v1 for Android followers (using
/// an optional Firebase service account).
final class FollowerPushSender {
    static let shared = FollowerPushSender()

    private init() {}

    private var cachedGoogleToken: (token: String, expiry: Date)?
    private let tokenQueue = DispatchQueue(label: "FollowerPushSender.tokenQueue")

    /// Sends an encrypted status blob to a follower using whichever push
    /// transport it registered.
    func sendStatus(encryptedStatus: String, to follower: PairedFollower) async throws {
        guard let token = follower.pushToken, !token.isEmpty else {
            throw FollowerPushError.notRegistered
        }

        switch follower.pushTransport {
        case "apns":
            try await sendViaAPNS(encryptedStatus: encryptedStatus, to: follower, token: token)
        case "fcm":
            try await sendViaFCM(encryptedStatus: encryptedStatus, to: follower, token: token)
        default:
            throw FollowerPushError.transportFailure("Unknown push transport: \(follower.pushTransport ?? "nil")")
        }
    }

    /// Sends a user-visible alert, as opposed to the silent status pushes.
    ///
    /// This is a separate message from the status push, so it costs the status
    /// payload's 4 KB budget nothing, and it displays even when the follower app
    /// has been swiped away — which is the whole reason alerts are evaluated on
    /// the host rather than in the app.
    func sendAlert(
        title: String,
        body: String,
        sound: FollowerAlertSound,
        to follower: PairedFollower
    ) async throws {
        guard let token = follower.pushToken, !token.isEmpty else {
            throw FollowerPushError.notRegistered
        }

        switch follower.pushTransport {
        case "apns":
            try await sendAlertViaAPNS(title: title, body: body, sound: sound, to: follower, token: token)
        case "fcm":
            try await sendAlertViaFCM(title: title, body: body, sound: sound, to: follower, token: token)
        default:
            throw FollowerPushError.transportFailure("Unknown push transport: \(follower.pushTransport ?? "nil")")
        }
    }

    // MARK: - APNS (iOS followers)

    private func sendViaAPNS(
        encryptedStatus: String,
        to follower: PairedFollower,
        token: String,
        allowEnvironmentRetry: Bool = true
    ) async throws {
        let manager = FollowerPairingManager.shared
        guard manager.hasAPNSCredentials else {
            throw FollowerPushError.missingAPNSCredentials
        }
        guard let jwt = APNSJWTManager.shared.getOrGenerateJWT(
            keyId: manager.apnsKeyId,
            teamId: manager.apnsTeamId,
            apnsKey: manager.apnsKey
        ) else {
            throw FollowerPushError.transportFailure("Failed to generate APNS JWT")
        }

        let production = follower.pushEnvironment != "sandbox"
        let host = production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else {
            throw FollowerPushError.transportFailure("Invalid APNS URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Background push: priority 5 wakes the follower app silently.
        request.setValue("5", forHTTPHeaderField: "apns-priority")
        request.setValue("background", forHTTPHeaderField: "apns-push-type")
        request.setValue(follower.pushBundleId ?? "", forHTTPHeaderField: "apns-topic")

        let payload: [String: Any] = [
            "aps": ["content-available": 1],
            "encrypted_status": encryptedStatus,
            "follower_id": follower.id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FollowerPushError.transportFailure("No HTTP response from APNS")
        }
        if httpResponse.statusCode == 200 {
            return
        }

        let reason = Self.apnsReason(from: data)
        // Debug builds of the follower register a sandbox token and vice
        // versa; if the stored environment is wrong, try the other one once
        // and remember the working environment.
        if reason == "BadDeviceToken", allowEnvironmentRetry {
            var flipped = follower
            flipped.pushEnvironment = production ? "sandbox" : "production"
            try await sendViaAPNS(
                encryptedStatus: encryptedStatus,
                to: flipped,
                token: token,
                allowEnvironmentRetry: false
            )
            FollowerPairingManager.shared.updatePushRegistration(
                followerId: follower.id,
                token: token,
                transport: "apns",
                bundleId: follower.pushBundleId,
                environment: flipped.pushEnvironment
            )
            return
        }
        throw FollowerPushError.transportFailure("APNS \(httpResponse.statusCode): \(reason ?? "unknown")")
    }

    private func sendAlertViaAPNS(
        title: String,
        body: String,
        sound: FollowerAlertSound,
        to follower: PairedFollower,
        token: String,
        allowEnvironmentRetry: Bool = true
    ) async throws {
        let manager = FollowerPairingManager.shared
        guard manager.hasAPNSCredentials else {
            throw FollowerPushError.missingAPNSCredentials
        }
        guard let jwt = APNSJWTManager.shared.getOrGenerateJWT(
            keyId: manager.apnsKeyId,
            teamId: manager.apnsTeamId,
            apnsKey: manager.apnsKey
        ) else {
            throw FollowerPushError.transportFailure("Failed to generate APNS JWT")
        }

        let production = follower.pushEnvironment != "sandbox"
        let host = production ? "api.push.apple.com" : "api.sandbox.push.apple.com"
        guard let url = URL(string: "https://\(host)/3/device/\(token)") else {
            throw FollowerPushError.transportFailure("Invalid APNS URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("bearer \(jwt)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        // Alert push: priority 10 delivers immediately, unlike the silent
        // status pushes the system is free to defer.
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("alert", forHTTPHeaderField: "apns-push-type")
        request.setValue(follower.pushBundleId ?? "", forHTTPHeaderField: "apns-topic")

        var aps: [String: Any] = [
            "alert": ["title": title, "body": body],
            "interruption-level": "time-sensitive"
        ]
        if let soundName = sound.apnsSoundName {
            aps["sound"] = soundName
        }

        let payload: [String: Any] = [
            "aps": aps,
            "follower_id": follower.id
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw FollowerPushError.transportFailure("No HTTP response from APNS")
        }
        if httpResponse.statusCode == 200 { return }

        let reason = Self.apnsReason(from: data)
        if reason == "BadDeviceToken", allowEnvironmentRetry {
            var flipped = follower
            flipped.pushEnvironment = production ? "sandbox" : "production"
            try await sendAlertViaAPNS(
                title: title,
                body: body,
                sound: sound,
                to: flipped,
                token: token,
                allowEnvironmentRetry: false
            )
            return
        }
        throw FollowerPushError.transportFailure("APNS \(httpResponse.statusCode): \(reason ?? "unknown")")
    }

    private func sendAlertViaFCM(
        title: String,
        body: String,
        sound: FollowerAlertSound,
        to follower: PairedFollower,
        token: String
    ) async throws {
        guard let account = FCMServiceAccount(json: FollowerPairingManager.shared.fcmServiceAccountJSON) else {
            throw FollowerPushError.missingFCMCredentials
        }

        let accessToken = try await googleAccessToken(for: account)
        guard let url = URL(string: "https://fcm.googleapis.com/v1/projects/\(account.projectId)/messages:send") else {
            throw FollowerPushError.transportFailure("Invalid FCM URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Android binds the sound to the channel, so the sound choice is carried
        // as the channel id; the follower app creates one channel per sound.
        let payload: [String: Any] = [
            "message": [
                "token": token,
                "notification": ["title": title, "body": body],
                "android": [
                    "priority": "HIGH",
                    "notification": ["channel_id": sound.androidChannelId]
                ]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FollowerPushError.transportFailure("FCM \(status): \(body.prefix(300))")
        }
    }

    private static func apnsReason(from data: Data) -> String? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["reason"] as? String
    }

    // MARK: - FCM (Android followers)

    private func sendViaFCM(encryptedStatus: String, to follower: PairedFollower, token: String) async throws {
        guard let account = FCMServiceAccount(json: FollowerPairingManager.shared.fcmServiceAccountJSON) else {
            throw FollowerPushError.missingFCMCredentials
        }

        let accessToken = try await googleAccessToken(for: account)

        guard let url = URL(string: "https://fcm.googleapis.com/v1/projects/\(account.projectId)/messages:send") else {
            throw FollowerPushError.transportFailure("Invalid FCM URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload: [String: Any] = [
            "message": [
                "token": token,
                "data": [
                    "encrypted_status": encryptedStatus,
                    "follower_id": follower.id
                ],
                "android": ["priority": "HIGH"]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw FollowerPushError.transportFailure("FCM \(status): \(body.prefix(300))")
        }
    }

    /// Mints (and caches) an OAuth2 access token for the FCM v1 API using the
    /// service account's RSA key (RS256-signed JWT bearer grant).
    private func googleAccessToken(for account: FCMServiceAccount) async throws -> String {
        if let cached = tokenQueue.sync(execute: { cachedGoogleToken }),
           cached.expiry > Date().addingTimeInterval(60)
        {
            return cached.token
        }

        let now = Int(Date().timeIntervalSince1970)
        let header = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": account.clientEmail,
            "scope": "https://www.googleapis.com/auth/firebase.messaging",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600
        ]

        let headerData = try JSONSerialization.data(withJSONObject: header)
        let claimsData = try JSONSerialization.data(withJSONObject: claims)
        let signingInput = "\(Self.base64URL(headerData)).\(Self.base64URL(claimsData))"

        guard let key = Self.rsaPrivateKey(fromPEM: account.privateKeyPEM) else {
            throw FollowerPushError.invalidServiceAccountKey
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            key,
            .rsaSignatureMessagePKCS1v15SHA256,
            Data(signingInput.utf8) as CFData,
            &error
        ) as Data? else {
            throw FollowerPushError.invalidServiceAccountKey
        }

        let assertion = "\(signingInput).\(Self.base64URL(signature))"

        guard let url = URL(string: "https://oauth2.googleapis.com/token") else {
            throw FollowerPushError.transportFailure("Invalid token URL")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(assertion)"
        request.httpBody = Data(body.utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String
        else {
            throw FollowerPushError.transportFailure("Google OAuth token exchange failed")
        }

        let expiresIn = (object["expires_in"] as? Double) ?? 3600
        tokenQueue.sync {
            cachedGoogleToken = (token, Date().addingTimeInterval(expiresIn))
        }
        return token
    }

    // MARK: - Key handling

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Loads an RSA private key from a PEM string. Service-account keys are
    /// PKCS#8; `SecKeyCreateWithData` needs PKCS#1, so the PKCS#8 wrapper is
    /// stripped first when present.
    static func rsaPrivateKey(fromPEM pem: String) -> SecKey? {
        let base64 = pem
            .components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard var der = Data(base64Encoded: base64) else { return nil }

        if let unwrapped = pkcs1Data(fromPKCS8: der) {
            der = unwrapped
        }

        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPrivate
        ]
        return SecKeyCreateWithData(der as CFData, attributes as CFDictionary, nil)
    }

    /// Minimal DER walk: PKCS#8 is SEQUENCE { INTEGER(0), SEQUENCE{OID,NULL},
    /// OCTET STRING { PKCS#1 } } — returns the OCTET STRING contents, or nil
    /// when the data is not a PKCS#8 wrapper (e.g. already PKCS#1).
    static func pkcs1Data(fromPKCS8 der: Data) -> Data? {
        var index = 0
        let bytes = [UInt8](der)

        func readLength() -> Int? {
            guard index < bytes.count else { return nil }
            var length = Int(bytes[index]); index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7F
                guard byteCount <= 4, index + byteCount <= bytes.count else { return nil }
                length = 0
                for _ in 0 ..< byteCount {
                    length = (length << 8) | Int(bytes[index]); index += 1
                }
            }
            return length
        }

        // Outer SEQUENCE
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard readLength() != nil else { return nil }

        // INTEGER version — absent in PKCS#1? No: PKCS#1 also starts with
        // INTEGER(0), so continue and look for the algorithm SEQUENCE next.
        guard index < bytes.count, bytes[index] == 0x02 else { return nil }
        index += 1
        guard let versionLength = readLength(), index + versionLength <= bytes.count else { return nil }
        index += versionLength

        // Algorithm identifier SEQUENCE — if it's not here, this is PKCS#1.
        guard index < bytes.count, bytes[index] == 0x30 else { return nil }
        index += 1
        guard let algorithmLength = readLength(), index + algorithmLength <= bytes.count else { return nil }
        index += algorithmLength

        // OCTET STRING wrapping the PKCS#1 key
        guard index < bytes.count, bytes[index] == 0x04 else { return nil }
        index += 1
        guard let keyLength = readLength(), index + keyLength <= bytes.count else { return nil }
        return Data(bytes[index ..< index + keyLength])
    }
}
