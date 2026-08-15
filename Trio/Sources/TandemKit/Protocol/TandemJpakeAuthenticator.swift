import CryptoKit
import Foundation

/// Key material produced by a successful JPAKE handshake.
struct TandemJpakeKeys {
    /// The long-lived shared secret. Persisting it lets later connections skip
    /// the expensive elliptic-curve rounds and re-key with a nonce exchange.
    let derivedSecret: Data
    /// This connection's HMAC key for signed control messages. Changes on every
    /// connection, because it is salted with a nonce the pump picks each time.
    let sessionKey: Data
}

extension TandemJpakeKeys {
    /// HKDF-SHA256 over the derived secret, salted with the pump's session
    /// nonce. Mirrors pumpX2's `Hkdf.build(nonce, keyMaterial)`, which is a
    /// standard extract-and-expand with an empty info and a 32-byte output.
    static func sessionKey(derivedSecret: Data, pumpNonce: Data) -> Data {
        let key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: derivedSecret),
            salt: pumpNonce,
            info: Data(),
            outputByteCount: 32
        )
        return key.withUnsafeBytes { Data($0) }
    }

    /// HMAC-SHA256 of a nonce under the session key: each side's proof that it
    /// derived the same key.
    static func confirmationDigest(nonce: Data, sessionKey: Data) -> Data {
        var hmac = HMAC<SHA256>(key: SymmetricKey(data: sessionKey))
        hmac.update(data: nonce)
        return Data(hmac.finalize())
    }
}

extension TandemPumpSession {
    private static let jpakeLog = TandemLogger(category: "Jpake")

    /// Authenticate with a JPAKE pump (Tandem Mobi, and t:slim X2 software 7.7+)
    /// using the 6-digit pairing code.
    ///
    /// Passing a previously stored `derivedSecret` runs only the nonce exchange
    /// and key confirmation, which is what every reconnection does; passing nil
    /// runs the full four-round handshake first.
    ///
    /// On success the session's signing key is set to this connection's session
    /// key and the caller should persist `derivedSecret`.
    func authenticateJpake(
        pairingCode: String,
        derivedSecret storedSecret: Data?,
        appInstanceId: UInt16 = 0
    ) -> Result<TandemJpakeKeys, TandemSessionError> {
        guard let codeBytes = Self.jpakePairingCodeBytes(pairingCode) else {
            return .failure(.pairingFailed("The pairing code should be 6 digits."))
        }

        // Fast path: we already know the shared secret, so only re-key.
        if let storedSecret = storedSecret, !storedSecret.isEmpty {
            switch confirmJpakeKey(derivedSecret: storedSecret, appInstanceId: appInstanceId) {
            case let .success(sessionKey):
                return .success(finishJpake(derivedSecret: storedSecret, sessionKey: sessionKey))
            case let .failure(error):
                // Only a failed confirmation means the stored secret is wrong
                // (the pump was re-paired, or an earlier pairing was cut short).
                // Any other failure is a comms problem and must not silently
                // discard a good secret.
                guard case .keyConfirmationFailed = error else { return .failure(error) }
                Self.jpakeLog.error("Stored pairing secret rejected by the pump; running a full handshake")
            }
        }

        let derivedSecret: Data
        switch runJpakeHandshake(codeBytes: codeBytes, appInstanceId: appInstanceId) {
        case let .success(secret): derivedSecret = secret
        case let .failure(error): return .failure(error)
        }

        switch confirmJpakeKey(derivedSecret: derivedSecret, appInstanceId: appInstanceId) {
        case let .success(sessionKey):
            return .success(finishJpake(derivedSecret: derivedSecret, sessionKey: sessionKey))
        case let .failure(error):
            return .failure(error)
        }
    }

    private func finishJpake(derivedSecret: Data, sessionKey: Data) -> TandemJpakeKeys {
        setAuthenticationKey(sessionKey)
        Self.jpakeLog.info("JPAKE authentication succeeded")
        delegate?.sessionDidAuthenticate(self)
        return TandemJpakeKeys(derivedSecret: derivedSecret, sessionKey: sessionKey)
    }

    // MARK: - Rounds 1 and 2

    /// The four elliptic-curve rounds, ending in the long-lived shared secret.
    ///
    /// This is the expensive part — roughly a dozen P-256 scalar
    /// multiplications — and runs only when pairing for the first time (or
    /// re-pairing). It must not be called on the main thread.
    private func runJpakeHandshake(
        codeBytes: Data,
        appInstanceId: UInt16
    ) -> Result<Data, TandemSessionError> {
        let jpake = TandemEcJpake(role: .client, secret: codeBytes)

        let round1: Data
        do {
            round1 = try jpake.round1()
        } catch {
            return .failure(.pairingFailed(error.localizedDescription))
        }
        guard round1.count == 2 * TandemJpakeSizes.roundHalfLength else {
            return .failure(.pairingFailed("Internal error building the pairing request."))
        }

        let firstHalf = round1.prefix(TandemJpakeSizes.roundHalfLength)
        let secondHalf = round1.suffix(TandemJpakeSizes.roundHalfLength)

        let response1a: TandemJpake1aResponse
        switch send(TandemJpake1aRequest(appInstanceId: appInstanceId, challenge: Data(firstHalf))) {
        case let .success(response): response1a = response
        case let .failure(error): return .failure(error)
        }

        let response1b: TandemJpake1bResponse
        switch send(TandemJpake1bRequest(appInstanceId: appInstanceId, challenge: Data(secondHalf))) {
        case let .success(response): response1b = response
        case let .failure(error): return .failure(error)
        }

        let round2: Data
        do {
            try jpake.readRound1(response1a.challengeHash + response1b.challengeHash)
            round2 = try jpake.round2()
        } catch {
            return .failure(.pairingFailed(error.localizedDescription))
        }

        let response2: TandemJpake2Response
        switch send(TandemJpake2Request(appInstanceId: appInstanceId, challenge: round2)) {
        case let .success(response): response2 = response
        case let .failure(error): return .failure(error)
        }

        do {
            try jpake.readRound2(response2.challengeHash)
            return .success(try jpake.deriveSecret())
        } catch {
            return .failure(.pairingFailed(error.localizedDescription))
        }
    }

    // MARK: - Rounds 3 and 4 (nonce exchange + key confirmation)

    /// Exchange nonces and prove, in both directions, that the two sides hold
    /// the same secret. Returns this connection's signing key.
    private func confirmJpakeKey(
        derivedSecret: Data,
        appInstanceId: UInt16
    ) -> Result<Data, TandemSessionError> {
        let sessionResponse: TandemJpake3SessionKeyResponse
        switch send(TandemJpake3SessionKeyRequest(challengeParameter: appInstanceId)) {
        case let .success(response): sessionResponse = response
        case let .failure(error): return .failure(error)
        }

        let sessionKey = TandemJpakeKeys.sessionKey(
            derivedSecret: derivedSecret,
            pumpNonce: sessionResponse.deviceKeyNonce
        )

        let ourNonce: Data
        do {
            ourNonce = try TandemSecureRandomSource().randomBytes(count: TandemJpakeSizes.nonceLength)
        } catch {
            return .failure(.pairingFailed(error.localizedDescription))
        }

        let confirmation: TandemJpake4KeyConfirmationResponse
        let request = TandemJpake4KeyConfirmationRequest(
            appInstanceId: appInstanceId,
            nonce: ourNonce,
            hashDigest: TandemJpakeKeys.confirmationDigest(nonce: ourNonce, sessionKey: sessionKey)
        )
        switch send(request) {
        case let .success(response): confirmation = response
        case let .failure(error): return .failure(error)
        }

        // Verify the pump's half of the proof in constant time. A mismatch means
        // the pairing code (or the stored secret) is wrong — never accept the
        // session key on an unverified digest.
        let valid = HMAC<SHA256>.isValidAuthenticationCode(
            confirmation.hashDigest,
            authenticating: confirmation.nonce,
            using: SymmetricKey(data: sessionKey)
        )
        guard valid else {
            return .failure(.keyConfirmationFailed)
        }
        return .success(sessionKey)
    }

    // MARK: - Pairing code

    /// The 6-digit code as pumpX2 encodes it: the ASCII bytes of the digits.
    /// Returns nil unless the code is exactly six digits after whitespace and
    /// separators are stripped.
    static func jpakePairingCodeBytes(_ code: String) -> Data? {
        let normalized = normalizePairingCode(code)
        guard normalized.count == 6, normalized.allSatisfy({ $0.isNumber && $0.isASCII }) else {
            return nil
        }
        return Data(normalized.utf8)
    }

    /// True when `code` looks like a JPAKE (6-digit) pairing code rather than a
    /// legacy 16-character one.
    static func isJpakePairingCode(_ code: String) -> Bool {
        jpakePairingCodeBytes(code) != nil
    }
}
