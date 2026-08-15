import Foundation
import Security

enum TandemSessionError: LocalizedError {
    case notConnected
    case requestInFlight
    case timeout
    case notAuthenticated
    case staleTimeSinceReset
    case insulinDeliveryActionsDisabled
    case pumpRejected(TandemErrorResponse)
    case transport(Error)
    case invalidResponse(Error)
    case pairingFailed(String)
    /// The pump's JPAKE key-confirmation digest did not match ours: the pairing
    /// code, or a stored pairing secret, is wrong.
    case keyConfirmationFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "The pump is not connected."
        case .requestInFlight: return "Another pump request is already in progress."
        case .timeout: return "Timed out waiting for the pump to respond."
        case .notAuthenticated: return "Not paired with the pump."
        case .staleTimeSinceReset: return "Pump time reference is stale; cannot sign the request safely."
        case .insulinDeliveryActionsDisabled:
            return "Remote insulin delivery actions are disabled. Enable them in the pump settings to allow this."
        case let .pumpRejected(error):
            return "The pump rejected the request (error code \(error.errorCodeId))."
        case let .transport(error): return error.localizedDescription
        case let .invalidResponse(error): return "Invalid pump response: \(error.localizedDescription)"
        case let .pairingFailed(reason): return "Pairing failed: \(reason)"
        case .keyConfirmationFailed:
            return "The pump did not accept the pairing code. Check the code and try again."
        }
    }
}

protocol TandemPumpSessionDelegate: AnyObject {
    func sessionDidAuthenticate(_ session: TandemPumpSession)
    func session(_ session: TandemPumpSession, didReceiveQualifyingEvents events: TandemQualifyingEvents)
    func session(_ session: TandemPumpSession, didDisconnect error: Error?)
}

/// Request/response orchestration on top of the BLE transport: transaction
/// ids, response reassembly, the legacy authentication handshake, and the
/// signing state (authentication key + pump time-since-reset) used by
/// control requests.
final class TandemPumpSession {
    private let log = TandemLogger(category: "Session")
    private let lock = NSRecursiveLock()

    let bluetooth: TandemBluetoothManager

    private var currentTxId: UInt8 = 0
    private var accumulators: [TandemCharacteristic: TandemResponseAccumulator] = [
        .currentStatus: TandemResponseAccumulator(),
        .authorization: TandemResponseAccumulator(),
        .control: TandemResponseAccumulator(),
        .historyLog: TandemResponseAccumulator()
    ]

    private struct PendingRequest {
        let txId: UInt8
        let expectedOpcode: UInt8
        let characteristic: TandemCharacteristic
        let signedResponse: Bool
        let semaphore: DispatchSemaphore
        var result: Result<TandemMessageFrame, TandemSessionError>?
    }

    private var pending: PendingRequest?

    /// The HMAC key for signed messages. Legacy pairing: the 16-character
    /// pairing code as UTF-8. Never persisted here — owned by the pump state.
    private var authenticationKey: Data?

    /// Pump time since reset, refreshed via TimeSinceResetRequest; signing
    /// uses the raw last-fetched value, mirroring pumpx2.
    private(set) var pumpTimeSinceReset: UInt32?
    private(set) var timeSinceResetFetchedAt: Date?

    /// Signed insulin-delivery commands are refused while false. Mirrors
    /// pumpx2's actionsAffectingInsulinDelivery gate; the user opt-in in the
    /// pump settings is the only place that enables it.
    var insulinDeliveryActionsEnabled = false

    /// Maximum age of the time-since-reset value acceptable for signing an
    /// insulin-affecting request; refreshed before each control command.
    static let maxTimeSinceResetAge: TimeInterval = 150

    weak var delegate: TandemPumpSessionDelegate?

    init(bluetooth: TandemBluetoothManager) {
        self.bluetooth = bluetooth
        bluetooth.delegate = self
    }

    func setAuthenticationKey(_ key: Data?) {
        lock.perform { authenticationKey = key }
    }

    var isAuthenticated: Bool {
        lock.perform { authenticationKey != nil }
    }

    // MARK: - Request/response

    /// Send a request and synchronously wait for its response. Must not be
    /// called on the bluetooth manager queue.
    func send<R: TandemRequest>(_ request: R, timeout: TimeInterval = 12) -> Result<R.Response, TandemSessionError> {
        if R.modifiesInsulinDelivery {
            guard lock.perform({ insulinDeliveryActionsEnabled }) else {
                log.error("Refusing \(String(describing: R.self)): insulin delivery actions are disabled")
                return .failure(.insulinDeliveryActionsDisabled)
            }
        }

        let txId: UInt8
        let semaphore = DispatchSemaphore(value: 0)
        let signingKey: Data?
        let timeSinceReset: UInt32?

        lock.lock()
        guard pending == nil else {
            lock.unlock()
            return .failure(.requestInFlight)
        }
        txId = currentTxId
        currentTxId = currentTxId &+ 1
        signingKey = authenticationKey
        timeSinceReset = pumpTimeSinceReset
        pending = PendingRequest(
            txId: txId,
            expectedOpcode: R.Response.opcode,
            characteristic: R.characteristic,
            signedResponse: R.Response.signed,
            semaphore: semaphore,
            result: nil
        )
        accumulators[R.characteristic]?.reset()
        lock.unlock()

        func fail(_ error: TandemSessionError) -> Result<R.Response, TandemSessionError> {
            lock.perform { pending = nil }
            return .failure(error)
        }

        if R.signed {
            guard signingKey != nil else { return fail(.notAuthenticated) }
            guard timeSinceReset != nil else { return fail(.staleTimeSinceReset) }
            // Every signed message folds pumpTimeSinceReset into its HMAC for
            // anti-replay, so the value must be fresh for ALL signed requests,
            // not only insulin-delivery ones (e.g. CancelBolusRequest must
            // sign with a current time or the pump rejects the cancel).
            let age = lock.perform { timeSinceResetFetchedAt.map { -$0.timeIntervalSinceNow } }
            guard let age = age, age < Self.maxTimeSinceResetAge else {
                return fail(.staleTimeSinceReset)
            }
        }

        do {
            let packets = try TandemPacketize.packetize(
                opcode: R.opcode,
                cargo: request.cargo,
                txId: txId,
                signed: R.signed,
                authenticationKey: signingKey,
                timeSinceReset: timeSinceReset,
                maxChunkSize: R.characteristic == .control
                    ? TandemPacketize.controlMaxChunkSize
                    : TandemPacketize.defaultMaxChunkSize
            )
            log.info("Sending \(String(describing: R.self)) txId=\(txId)")
            try bluetooth.write(packets: packets, to: R.characteristic)
        } catch {
            return fail(.transport(error))
        }

        guard semaphore.wait(timeout: .now() + timeout) == .success else {
            log.error("\(String(describing: R.self)) timed out")
            return fail(.timeout)
        }

        let outcome: Result<TandemMessageFrame, TandemSessionError>? = lock.perform {
            let result = pending?.result
            pending = nil
            return result
        }

        switch outcome {
        case let .success(frame):
            do {
                let cargo = R.Response.signed ? frame.unsignedCargo : frame.cargo
                return .success(try R.Response(cargo: cargo))
            } catch {
                return .failure(.invalidResponse(error))
            }
        case let .failure(error):
            return .failure(error)
        case nil:
            return .failure(.timeout)
        }
    }

    // MARK: - Authentication (legacy 16-character pairing code)

    /// Perform the CentralChallenge/PumpChallenge handshake. On success the
    /// pairing code becomes the signing key for this session.
    ///
    /// This is the t:slim X2 flow for software 7.1-7.6. Pumps on 7.7+ and every
    /// Tandem Mobi use the 6-digit JPAKE flow instead — see
    /// `authenticateJpake(pairingCode:derivedSecret:appInstanceId:)`.
    func authenticate(pairingCode: String, appInstanceId: UInt16 = 1) -> Result<Void, TandemSessionError> {
        let normalized = Self.normalizePairingCode(pairingCode)
        guard normalized.count == 16 else {
            return .failure(.pairingFailed(
                "The pairing code should be 16 letters and numbers."
            ))
        }

        var challenge = Data(count: 8)
        let status = challenge.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        guard status == errSecSuccess else {
            return .failure(.pairingFailed("Could not generate a secure random challenge."))
        }

        let central = TandemCentralChallengeRequest(appInstanceId: appInstanceId, centralChallenge: challenge)
        let centralResult = send(central)
        let centralResponse: TandemCentralChallengeResponse
        switch centralResult {
        case let .success(response): centralResponse = response
        case let .failure(error): return .failure(error)
        }

        let codeData = Data(normalized.utf8)
        let challengeHash = TandemPacketize.hmacSHA1(centralResponse.hmacKey, key: codeData)
        let pumpChallenge = TandemPumpChallengeRequest(appInstanceId: appInstanceId, pumpChallengeHash: challengeHash)

        switch send(pumpChallenge) {
        case let .success(response):
            guard response.success else {
                return .failure(.pairingFailed("The pump did not accept the pairing code. Check the code on the pump screen."))
            }
            setAuthenticationKey(codeData)
            log.info("Authentication succeeded")
            delegate?.sessionDidAuthenticate(self)
            return .success(())
        case let .failure(error):
            return .failure(error)
        }
    }

    /// Strip whitespace and dashes; the pump shows the code in groups of 4.
    static func normalizePairingCode(_ code: String) -> String {
        String(code.filter { $0.isLetter || $0.isNumber })
    }

    /// Refresh the pump time reference used for signing.
    @discardableResult func refreshTimeSinceReset() -> Result<TandemTimeSinceResetResponse, TandemSessionError> {
        let result = send(TandemTimeSinceResetRequest())
        if case let .success(response) = result {
            lock.perform {
                pumpTimeSinceReset = response.pumpTimeSinceReset
                timeSinceResetFetchedAt = Date()
            }
        }
        return result
    }
}

// MARK: - TandemBluetoothManagerDelegate

extension TandemPumpSession: TandemBluetoothManagerDelegate {
    func bluetoothManagerReady(_: TandemBluetoothManager) {
        lock.perform {
            for accumulator in accumulators.values {
                accumulator.reset()
            }
        }
    }

    func bluetoothManager(_: TandemBluetoothManager, didDisconnect error: Error?) {
        lock.perform {
            if var request = pending {
                request.result = .failure(.notConnected)
                pending = request
                request.semaphore.signal()
            }
        }
        delegate?.session(self, didDisconnect: error)
    }

    func bluetoothManager(_: TandemBluetoothManager, didReceive packet: Data, on characteristic: TandemCharacteristic) {
        lock.lock()
        defer { lock.unlock() }

        guard var request = pending, request.characteristic == characteristic else {
            // Unsolicited traffic (e.g. responses triggered by the pump UI);
            // ignored in this driver.
            return
        }

        let signingKey = authenticationKey
        do {
            guard let frame = try accumulators[characteristic]?.accumulate(
                packet: packet,
                expectedTxId: request.txId,
                signed: request.signedResponse,
                authenticationKey: signingKey
            ) else {
                return // more packets needed
            }

            if frame.opcode == TandemErrorResponse.opcode, frame.opcode != request.expectedOpcode {
                let error = try TandemErrorResponse(cargo: frame.cargo)
                request.result = .failure(.pumpRejected(error))
            } else if frame.opcode == request.expectedOpcode {
                request.result = .success(frame)
            } else {
                request.result = .failure(.invalidResponse(
                    TandemMessageError.unexpectedResponseOpcode(found: frame.opcode, expected: request.expectedOpcode)
                ))
            }
            pending = request
            request.semaphore.signal()
        } catch {
            log.error("Failed to parse packet: \(error.localizedDescription)")
            accumulators[characteristic]?.reset()
            request.result = .failure(.invalidResponse(error))
            pending = request
            request.semaphore.signal()
        }
    }

    func bluetoothManager(_: TandemBluetoothManager, didReceiveQualifyingEvents events: TandemQualifyingEvents) {
        delegate?.session(self, didReceiveQualifyingEvents: events)
    }
}
