import Foundation
import Testing

@testable import Trio

@Suite("Tandem diagnostics report") struct TandemDiagnosticsReportTests {
    @Test("Each outcome renders a distinct, greppable line") func probeLines() {
        #expect(TandemDiagnosticProbe(name: "Battery", query: "currentStatus op 144", outcome: .ok("80%")).line
            == "✓ Battery: 80%")
        #expect(TandemDiagnosticProbe(name: "X", query: "q", outcome: .refused("status 1")).line
            .contains("refused"))
        #expect(TandemDiagnosticProbe(name: "X", query: "q", outcome: .failed("timed out")).line
            .hasPrefix("✗"))
        #expect(TandemDiagnosticProbe(name: "X", query: "q", outcome: .skipped("busy")).line
            .contains("skipped"))
    }

    @Test("The report counts successes and stitches header plus lines") func reportText() {
        var report = TandemDiagnosticsReport()
        report.header = ["Tandem pump diagnostics", "Model: Tandem Mobi"]
        report.probes = [
            TandemDiagnosticProbe(name: "A", query: "q", outcome: .ok("one")),
            TandemDiagnosticProbe(name: "B", query: "q", outcome: .ok("two")),
            TandemDiagnosticProbe(name: "C", query: "q", outcome: .failed("no answer")),
        ]
        #expect(report.okCount == 2)
        #expect(!report.isEmpty)
        #expect(report.text.contains("Tandem pump diagnostics"))
        #expect(report.text.contains("✓ A: one"))
        #expect(report.text.contains("✗ C: no answer"))
        #expect(report.summaryLine.contains("2"))
    }

    @Test("Hex helper renders raw cargo without separators") func hex() {
        #expect(Data([0x00, 0x0f, 0xa4, 0xff]).tandemHexString == "000fa4ff")
        #expect(Data().tandemHexString == "")
    }
}

/// The diagnostics engine can only send an unsigned currentStatus query — its
/// `probe` guard refuses anything else *before* it reaches the pump. These
/// tests pin the classification that guard depends on, so the safety property
/// holds against the real message types rather than a comment.
@Suite("Tandem diagnostics safety envelope") struct TandemDiagnosticsSafetyTests {
    /// A request the diagnostics guard MUST accept: unsigned, non-delivery,
    /// on the currentStatus characteristic.
    private func expectReadable<R: TandemRequest>(_: R.Type, _ name: String) {
        #expect(R.characteristic == .currentStatus, "\(name) must be a currentStatus query")
        #expect(!R.signed, "\(name) must be unsigned")
        #expect(!R.modifiesInsulinDelivery, "\(name) must not modify delivery")
    }

    /// A request the guard MUST refuse: it is not an unsigned currentStatus
    /// read, so diagnostics can never send it.
    private func expectRefused<R: TandemRequest>(_: R.Type, _ name: String) {
        let isSafeReadOnly = R.characteristic == .currentStatus && !R.signed && !R.modifiesInsulinDelivery
        #expect(!isSafeReadOnly, "\(name) must NOT be classifiable as a safe read-only query")
    }

    @Test("The REAL curated list is enumerated and every entry is a read-only status query") func manifestIsSafe() {
        // This checks the actual list the sweep is built from, not a parallel
        // copy. Its element type is the read-only marker, so a delivery command
        // could not compile into it; this asserts each is truly unsigned,
        // non-delivery, and on currentStatus.
        let types = TandemPumpManager.diagnosticReadOnlyTypes
        #expect(types.count == 14, "the manifest and diagnosticProbeList must stay in lockstep")
        for type in types {
            #expect(type.characteristic == .currentStatus, "\(type) must be a currentStatus query")
            #expect(!type.signed, "\(type) must be unsigned")
            #expect(!type.modifiesInsulinDelivery, "\(type) must not modify delivery")
        }
    }

    @Test("Every query the diagnostics sweep uses is a safe read-only status read") func readOnlySet() {
        expectReadable(TandemPumpVersionRequest.self, "PumpVersion")
        expectReadable(TandemApiVersionRequest.self, "ApiVersion")
        expectReadable(TandemPumpGlobalsRequest.self, "PumpGlobals")
        expectReadable(TandemCurrentBatteryV2Request.self, "CurrentBatteryV2")
        expectReadable(TandemInsulinStatusRequest.self, "InsulinStatus")
        expectReadable(TandemCurrentBasalStatusRequest.self, "CurrentBasalStatus")
        expectReadable(TandemControlIQInfoV1Request.self, "ControlIQInfoV1")
        expectReadable(TandemHomeScreenMirrorRequest.self, "HomeScreenMirror")
        expectReadable(TandemTimeSinceResetRequest.self, "TimeSinceReset")
        expectReadable(TandemCurrentEGVGuiDataRequest.self, "CurrentEGVGuiData")
        expectReadable(TandemLoadStatusRequest.self, "LoadStatus")
        expectReadable(TandemAlarmStatusRequest.self, "AlarmStatus")
        expectReadable(TandemAlertStatusRequest.self, "AlertStatus")
        expectReadable(TandemLastBolusStatusV2Request.self, "LastBolusStatusV2")
    }

    @Test("Every delivery command is refused by the same classification") func deliverySetRefused() {
        // Insulin-moving commands: signed, on control, modifiesInsulinDelivery.
        expectRefused(TandemInitiateBolusRequest.self, "InitiateBolus")
        expectRefused(TandemSetTempRateRequest.self, "SetTempRate")
        expectRefused(TandemStopTempRateRequest.self, "StopTempRate")
        expectRefused(TandemSuspendPumpingRequest.self, "SuspendPumping")
        expectRefused(TandemResumePumpingRequest.self, "ResumePumping")
        expectRefused(TandemEnterChangeCartridgeModeRequest.self, "EnterChangeCartridgeMode")
        expectRefused(TandemEnterFillTubingModeRequest.self, "EnterFillTubingMode")
        expectRefused(TandemFillCannulaRequest.self, "FillCannula")
    }

    @Test("Signed control messages that don't move insulin are still refused") func signedNonDeliveryRefused() {
        // These carry modifiesInsulinDelivery == false, so a guard that only
        // checked that flag would wrongly allow them. They live on the control
        // characteristic, so the characteristic check is what blocks them —
        // proving the guard does not rely on the flag alone.
        #expect(!TandemPlaySoundRequest.modifiesInsulinDelivery)
        expectRefused(TandemPlaySoundRequest.self, "PlaySound")
        #expect(!TandemDismissNotificationRequest.modifiesInsulinDelivery)
        expectRefused(TandemDismissNotificationRequest.self, "DismissNotification")
        // The opcode-collision trap the classification must survive: 0xA4 is a
        // harmless read on currentStatus but SetTempRate on control. They are
        // told apart by characteristic, never by opcode.
        #expect(TandemLastBolusStatusV2Request.opcode == TandemSetTempRateRequest.opcode)
        #expect(TandemLastBolusStatusV2Request.characteristic != TandemSetTempRateRequest.characteristic)
    }
}
