import Foundation
import LoopKit

/// A pump self-report: what Trio asked, and what the pump answered.
///
/// This is the read-only "connect to the Mobi and extract data" tool. It is
/// deliberately the safest possible way to talk to the pump — see the safety
/// note on `TandemPumpManager.runPumpDiagnostics(completion:)`.
enum TandemDiagnostics {}

/// A request that only **reads** pump state.
///
/// This is a *positive opt-in*, and it is the load-bearing safety mechanism of
/// the diagnostics tool. `probe(_:_:_:)` requires it, so a signed or
/// delivery-modifying command cannot even be written into the diagnostics
/// sweep — it would fail to compile, not merely be refused at runtime. And it
/// is a marker a request must adopt deliberately, rather than being inferred
/// from the *absence* of the signed/delivery flags: an unsigned `currentStatus`
/// *write* (the protocol has them, e.g. `CreateHistoryLog`) does not become
/// read-only just by leaving those flags unset, so it is not one of these.
///
/// Only conform a type here after confirming it is an unsigned `currentStatus`
/// status query. `TandemDiagnosticsTests` enumerates the conformers and asserts
/// exactly that.
protocol TandemReadOnlyStatusRequest: TandemRequest {}

// The curated read-only set. Each is a genuine unsigned currentStatus status
// query; the conformance is what lets it into the diagnostics sweep.
extension TandemPumpVersionRequest: TandemReadOnlyStatusRequest {}
extension TandemApiVersionRequest: TandemReadOnlyStatusRequest {}
extension TandemPumpGlobalsRequest: TandemReadOnlyStatusRequest {}
extension TandemCurrentBatteryV2Request: TandemReadOnlyStatusRequest {}
extension TandemInsulinStatusRequest: TandemReadOnlyStatusRequest {}
extension TandemCurrentBasalStatusRequest: TandemReadOnlyStatusRequest {}
extension TandemControlIQInfoV1Request: TandemReadOnlyStatusRequest {}
extension TandemHomeScreenMirrorRequest: TandemReadOnlyStatusRequest {}
extension TandemTimeSinceResetRequest: TandemReadOnlyStatusRequest {}
extension TandemCurrentEGVGuiDataRequest: TandemReadOnlyStatusRequest {}
extension TandemLoadStatusRequest: TandemReadOnlyStatusRequest {}
extension TandemAlarmStatusRequest: TandemReadOnlyStatusRequest {}
extension TandemAlertStatusRequest: TandemReadOnlyStatusRequest {}
extension TandemLastBolusStatusV2Request: TandemReadOnlyStatusRequest {}

/// One line of the report: a single query and its result.
struct TandemDiagnosticProbe: Equatable {
    let name: String
    /// The characteristic and opcode used, recorded verbatim because the point
    /// of the report is to be pasted into a bug thread and read months later.
    let query: String
    let outcome: Outcome

    enum Outcome: Equatable {
        /// The pump answered and Trio decoded it. `summary` is human-readable.
        case ok(String)
        /// The pump answered the query with an error or NACK.
        case refused(String)
        /// No usable answer — a link drop, a timeout, or a local error.
        case failed(String)
        /// Not run. Either the query was not a safe read-only status request
        /// (refused *before* anything was sent), or the sweep was stopped
        /// because the pump became busy with delivery.
        case skipped(String)
    }

    var line: String {
        switch outcome {
        case let .ok(summary): return "✓ \(name): \(summary)"
        case let .refused(why): return "⚠ \(name): pump refused — \(why)"
        case let .failed(why): return "✗ \(name): \(why)"
        case let .skipped(why): return "· \(name): skipped — \(why)"
        }
    }
}

/// The whole report, ready to show, copy, or paste into a log.
struct TandemDiagnosticsReport: Equatable {
    var header: [String] = []
    var probes: [TandemDiagnosticProbe] = []

    var okCount: Int {
        probes.filter { if case .ok = $0.outcome { return true } else { return false } }.count
    }

    var isEmpty: Bool { probes.isEmpty }

    /// The full report as one block of text.
    var text: String {
        (header + [""] + probes.map(\.line)).joined(separator: "\n")
    }

    /// A one-line headline for the UI: "12 of 14 reads succeeded".
    var summaryLine: String {
        String(localized: "\(okCount) of \(probes.count) reads succeeded")
    }
}

extension Data {
    /// Lowercase hex with no separators, for dumping raw cargo into a report.
    var tandemHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

extension TandemPumpManager {
    // MARK: - Read-only pump diagnostics

    /// The read-only status queries the diagnostics sweep uses, as types, so a
    /// test can enumerate the *real* curated set and assert every one is an
    /// unsigned currentStatus query. The element type is the read-only marker,
    /// so a delivery command cannot even appear in this list — it would not
    /// compile. Kept in lockstep with `diagnosticProbeList()` below.
    static let diagnosticReadOnlyTypes: [any TandemReadOnlyStatusRequest.Type] = [
        TandemPumpVersionRequest.self,
        TandemApiVersionRequest.self,
        TandemPumpGlobalsRequest.self,
        TandemCurrentBatteryV2Request.self,
        TandemInsulinStatusRequest.self,
        TandemCurrentBasalStatusRequest.self,
        TandemControlIQInfoV1Request.self,
        TandemHomeScreenMirrorRequest.self,
        TandemTimeSinceResetRequest.self,
        TandemCurrentEGVGuiDataRequest.self,
        TandemLoadStatusRequest.self,
        TandemAlarmStatusRequest.self,
        TandemAlertStatusRequest.self,
        TandemLastBolusStatusV2Request.self,
    ]

    /// Ask the pump everything it will tell us about itself, and hand back a
    /// report. This is the in-app equivalent of "connect and extract data".
    ///
    /// **Why this is safe — by construction, not by care.** An insulin pump is
    /// the last device you want a diagnostics tool to misfire against, so the
    /// guarantees here are structural:
    ///
    /// 1. **It can only send a read-only status query — enforced by the
    ///    compiler.** `probe(_:_:_:)` accepts only a `TandemReadOnlyStatusRequest`,
    ///    a marker a request must positively opt into. A signed or
    ///    delivery-modifying command cannot be written into the sweep at all:
    ///    it would not conform, so it would not compile. As belt-and-suspenders,
    ///    `probe` *also* re-checks at runtime that the request is unsigned,
    ///    non-delivery, and on the `currentStatus` characteristic, and refuses
    ///    before sending if not — catching even a mistaken conformance. Every
    ///    insulin-moving command is signed and on `control`, so moving insulin
    ///    from here is doubly impossible.
    /// 2. **It never delays a dose.** Each probe is its own `commandQueue`
    ///    item, so a real therapy command enqueued mid-report waits at most one
    ///    probe's round trip, not the whole report — the same discipline the
    ///    annunciation code uses. Probes use a short 6 s timeout.
    /// 3. **It yields to delivery.** It does not start while a bolus or
    ///    cartridge change is active, and it stops if one begins.
    ///
    /// It is read-only, so it needs no opt-in; it will connect if it has to.
    func runPumpDiagnostics(completion: @escaping (TandemDiagnosticsReport) -> Void) {
        commandQueue.async { [weak self] in
            guard let self = self else { return }
            var report = TandemDiagnosticsReport()
            report.header = self.diagnosticsHeader()

            guard self.state.activeBolus == nil, !self.state.cartridgeChangeInProgress else {
                report.probes.append(TandemDiagnosticProbe(
                    name: String(localized: "Diagnostics"),
                    query: "-",
                    outcome: .skipped(String(
                        localized: "the pump is mid-delivery; run this when it is idle so a read never delays insulin"
                    ))
                ))
                self.deliverDiagnostics(report, completion: completion)
                return
            }

            if let error = self.ensureConnectedAndAuthenticated() {
                report.probes.append(TandemDiagnosticProbe(
                    name: String(localized: "Connect and authenticate"),
                    query: "-",
                    outcome: .failed(error.localizedDescription)
                ))
                self.deliverDiagnostics(report, completion: completion)
                return
            }

            self.runDiagnosticProbes(self.diagnosticProbeList(), index: 0, report: report, completion: completion)
        }
    }

    /// Run one probe per `commandQueue` hop so delivery can slip in between.
    private func runDiagnosticProbes(
        _ probes: [() -> TandemDiagnosticProbe],
        index: Int,
        report: TandemDiagnosticsReport,
        completion: @escaping (TandemDiagnosticsReport) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        var report = report

        guard index < probes.count else {
            deliverDiagnostics(report, completion: completion)
            return
        }

        // Delivery takes precedence the instant it appears.
        guard state.activeBolus == nil, !state.cartridgeChangeInProgress else {
            report.probes.append(TandemDiagnosticProbe(
                name: String(localized: "Diagnostics"),
                query: "-",
                outcome: .skipped(String(localized: "stopped early — the pump started delivering"))
            ))
            deliverDiagnostics(report, completion: completion)
            return
        }

        report.probes.append(probes[index]())

        let next = index + 1
        commandQueue.async { [weak self] in
            self?.runDiagnosticProbes(probes, index: next, report: report, completion: completion)
        }
    }

    /// Send one already-modeled, read-only status request and summarise the
    /// reply. The `TandemReadOnlyStatusRequest` bound means only a read-only
    /// query even type-checks here; the runtime guard below is a second line.
    private func probe<R: TandemReadOnlyStatusRequest>(
        _ name: String,
        _ request: R,
        _ summarize: (R.Response) -> String
    ) -> TandemDiagnosticProbe {
        dispatchPrecondition(condition: .onQueue(commandQueue))
        let query = "\(Self.characteristicName(R.characteristic)) op \(R.opcode)"

        // Belt-and-suspenders behind the compile-time bound: even a request that
        // wrongly claimed the read-only marker is refused here if it is signed,
        // delivery-modifying, or off the currentStatus characteristic. Every
        // insulin-moving command is signed and on `control`, so this makes
        // delivery structurally unreachable from diagnostics.
        guard R.characteristic == .currentStatus, !R.signed, !R.modifiesInsulinDelivery else {
            log.error("Diagnostics refused an unsafe probe \(name) (\(query)); not sent")
            return TandemDiagnosticProbe(
                name: name,
                query: query,
                outcome: .skipped(String(localized: "not a safe read-only query — refused before sending"))
            )
        }

        switch session.send(request, timeout: 6) {
        case let .success(response):
            return TandemDiagnosticProbe(name: name, query: query, outcome: .ok(summarize(response)))
        case let .failure(error):
            if case let .pumpRejected(err) = error {
                return TandemDiagnosticProbe(name: name, query: query, outcome: .refused(err.localizedDescription))
            }
            return TandemDiagnosticProbe(name: name, query: query, outcome: .failed(error.localizedDescription))
        }
    }

    /// The curated set of read-only status queries. Hand-picked concrete
    /// request types — never a table of opcodes, never a filter over a flag —
    /// so the compiler itself vouches that each entry is a known, modeled read.
    ///
    /// The summaries are deliberately plain, un-localised technical strings:
    /// the report exists to be pasted into a bug thread and read as raw pump
    /// state, not translated.
    private func diagnosticProbeList() -> [() -> TandemDiagnosticProbe] {
        [
            { self.probe("Firmware & serial", TandemPumpVersionRequest()) { r in
                "model \(r.modelNum), serial \(r.serialNum), arm sw \(r.armSwVer)"
            } },
            { self.probe("API version", TandemApiVersionRequest()) { r in
                "\(r.majorVersion).\(r.minorVersion)"
            } },
            { self.probe("Sound configuration", TandemPumpGlobalsRequest()) { r in
                r.localizedSoundSummary + (r.allVibrate ? " — all vibrate, so speaker tones may be declined" : "")
            } },
            { self.probe("Battery", TandemCurrentBatteryV2Request()) { r in
                "\(Int(r.currentBatteryIbc))%, charging id \(Int(r.chargingStatus))"
            } },
            { self.probe("Insulin remaining", TandemInsulinStatusRequest()) { r in
                let estimate = r.isEstimate ? " (estimate)" : ""
                return "\(Int(r.currentInsulinAmount)) U\(estimate), low-at \(Int(r.insulinLowAmount)) U"
            } },
            { self.probe("Basal rate", TandemCurrentBasalStatusRequest()) { r in
                "profile \(Self.units(r.profileBasalRate)) U/hr, current \(Self.units(r.currentBasalRate)) U/hr"
            } },
            { self.probe("Loop / Control-IQ", TandemControlIQInfoV1Request()) { r in
                "closed loop \(r.closedLoopEnabled ? "on" : "off"), user-mode id \(Int(r.currentUserModeType))"
            } },
            { self.probe("Home screen", TandemHomeScreenMirrorRequest()) { r in
                "basal icon \(Int(r.basalStatusIconId)), bolus icon \(Int(r.bolusStatusIconId)), CGM trend \(Int(r.cgmTrendIconId)), AP state \(Int(r.apControlStateIconId))"
            } },
            { self.probe("Pump clock", TandemTimeSinceResetRequest()) { r in
                "time \(Int(r.currentTime)), since-reset \(Int(r.pumpTimeSinceReset))"
            } },
            { self.probe("CGM reading", TandemCurrentEGVGuiDataRequest()) { r in
                "\(Int(r.cgmReading)) mg/dL, status id \(Int(r.egvStatusId)), trend \(Int(r.trendRate))"
            } },
            { self.probe("Load state", TandemLoadStatusRequest()) { r in
                r.localizedDescription + " [" + r.diagnosticDescription + "]"
            } },
            { self.probe("Active alarms", TandemAlarmStatusRequest()) { r in
                r.localizedNames ?? "none"
            } },
            { self.probe("Active alerts", TandemAlertStatusRequest()) { r in
                let load = r.localizedLoadRelatedNames.map { "load: \($0); " } ?? ""
                return load + "bitmask 0x" + String(r.bitmask, radix: 16)
            } },
            { self.probe("Last bolus", TandemLastBolusStatusV2Request()) { r in
                "id \(Int(r.bolusId)), delivered \(Self.units(r.deliveredVolume)) U, status id \(Int(r.bolusStatusId))"
            } },
        ]
    }

    /// Milliunits (thousandths of a unit) rendered as a plain unit string.
    private static func units(_ milliunits: UInt32) -> String {
        String(format: "%.3f", Double(milliunits) / 1000)
    }

    private func diagnosticsHeader() -> [String] {
        let pairing = state.pairingCodeType == .jpake6 ? "6-digit JPAKE" : "16-char legacy"
        return [
            "Tandem pump diagnostics",
            "Model: \(state.pumpModel.localizedTitle)",
            "Pairing: \(pairing)",
            "Remote bolus: \(state.remoteBolusEnabled ? "on" : "off")   Remote basal: \(state.remoteBasalEnabled ? "on" : "off")   Microbolus basal: \(state.microbolusBasalEnabled ? "on" : "off")",
        ]
    }

    private func deliverDiagnostics(
        _ report: TandemDiagnosticsReport,
        completion: @escaping (TandemDiagnosticsReport) -> Void
    ) {
        // The log is the primary channel — field reports come out through it —
        // so the whole report goes there regardless of the UI.
        log.info("Pump diagnostics:\n\(report.text)")
        DispatchQueue.main.async { completion(report) }
    }

    private static func characteristicName(_ characteristic: TandemCharacteristic) -> String {
        switch characteristic {
        case .currentStatus: return "currentStatus"
        case .authorization: return "authorization"
        case .control: return "control"
        case .controlStream: return "controlStream"
        case .historyLog: return "historyLog"
        }
    }
}
