import LoopKit
import SwiftUI

final class TandemSettingsViewModel: ObservableObject {
    @Published var refreshing = false
    @Published var remoteBolusEnabled: Bool
    @Published var showRemoteBolusWarning = false
    @Published var microbolusBasalEnabled: Bool
    @Published var showMicrobolusWarning = false
    @Published var showDeleteConfirmation = false
    @Published var audioFeedbackEnabled: Bool
    @Published var audioFeedbackForAutomaticDoses: Bool
    @Published var showTestDoseConfirmation = false
    @Published var testDoseInProgress = false
    @Published var testDoseResult: (success: Bool, message: String)?

    let pumpManager: TandemPumpManager

    var didFinish: (() -> Void)?
    var didDeletePump: (() -> Void)?

    init(pumpManager: TandemPumpManager) {
        self.pumpManager = pumpManager
        remoteBolusEnabled = pumpManager.state.remoteBolusEnabled
        microbolusBasalEnabled = pumpManager.state.microbolusBasalEnabled
        audioFeedbackEnabled = pumpManager.state.audioFeedbackEnabled
        audioFeedbackForAutomaticDoses = pumpManager.state.audioFeedbackForAutomaticDoses
    }

    var state: TandemPumpState { pumpManager.state }

    /// The pump's own basal must be zeroed and Control-IQ off for microbolus-basal.
    var microbolusPreconditionsMet: Bool {
        pumpManager.microbolusBasalPreconditionsMet()
    }

    var preconditionDetail: String {
        if state.lastSync == .distantPast {
            return String(localized: "Waiting for a status sync from the pump…")
        }
        var problems: [String] = []
        if state.profileBasalRate > 0.05 {
            problems.append(String(localized: "pump basal is \(String(format: "%.2f", state.profileBasalRate)) U/hr (must be 0)"))
        }
        if state.controlIQEnabled {
            problems.append(String(localized: "Control-IQ is on (must be off)"))
        }
        return problems.isEmpty
            ? String(localized: "Pump basal is 0 U/hr and Control-IQ is off — ready.")
            : problems.joined(separator: "; ")
    }

    var lastSyncText: String {
        guard state.lastSync != .distantPast else { return String(localized: "Never") }
        let formatter = RelativeDateTimeFormatter()
        return formatter.localizedString(for: state.lastSync, relativeTo: Date.now)
    }

    var apiVersionText: String {
        guard state.apiVersionMajor > 0 else { return "-" }
        return "\(state.apiVersionMajor).\(state.apiVersionMinor)"
    }

    func refresh() {
        refreshing = true
        pumpManager.state.lastSync = .distantPast
        pumpManager.ensureCurrentPumpData { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshing = false
                self?.objectWillChange.send()
            }
        }
    }

    func requestRemoteBolusChange(_ enabled: Bool) {
        if enabled {
            showRemoteBolusWarning = true
        } else {
            remoteBolusEnabled = false
            pumpManager.setRemoteBolusEnabled(false)
        }
    }

    func confirmRemoteBolusEnable() {
        remoteBolusEnabled = true
        pumpManager.setRemoteBolusEnabled(true)
    }

    func cancelRemoteBolusEnable() {
        remoteBolusEnabled = false
    }

    func requestMicrobolusChange(_ enabled: Bool) {
        if enabled {
            showMicrobolusWarning = true
        } else {
            microbolusBasalEnabled = false
            pumpManager.setMicrobolusBasalEnabled(false)
        }
    }

    func confirmMicrobolusEnable() {
        microbolusBasalEnabled = true
        remoteBolusEnabled = true
        pumpManager.setMicrobolusBasalEnabled(true)
    }

    func cancelMicrobolusEnable() {
        microbolusBasalEnabled = false
    }

    /// The smallest dose the driver can command: 1 milliunit.
    static let testDoseUnits: Double = 0.001

    func requestTestDose() {
        testDoseResult = nil
        showTestDoseConfirmation = true
    }

    /// Deliver a single 0.001 U bolus through the normal remote-bolus path to
    /// find out whether the pump accepts a dose this small. The regular
    /// enactBolus flow is used on purpose: the test exercises the exact
    /// permission → initiate → reconcile sequence production dosing uses, and
    /// the delivered insulin is recorded in the treatment log like any bolus.
    func confirmTestDose() {
        testDoseInProgress = true
        pumpManager.enactBolus(units: Self.testDoseUnits, activationType: .manualNoRecommendation) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.testDoseInProgress = false
                if let error {
                    if case .uncertainDelivery = error {
                        // Not a rejection: communication dropped mid-command, so
                        // the pump may or may not have delivered. Says nothing
                        // about whether 0.001 U doses are accepted.
                        self.testDoseResult = (
                            success: false,
                            message: String(
                                localized: "Communication was lost mid-command, so it is unknown whether the test bolus was delivered — this does not tell us whether the pump accepts 0.001 U. Check the pump's bolus history, then try again."
                            )
                        )
                    } else {
                        self.testDoseResult = (
                            success: false,
                            message: String(localized: "The pump did not accept the test bolus: \(error.localizedDescription)")
                        )
                    }
                } else {
                    self.testDoseResult = (
                        success: true,
                        message: String(
                            localized: "The pump accepted the 0.001 U test bolus. It is recorded in Trio's treatment log — confirm in the pump's own bolus history that 0.001 U was actually delivered."
                        )
                    )
                    // A 1-milliunit bolus completes almost instantly; refresh
                    // shortly after so the delivery reconciles and the
                    // single-bolus gate releases without waiting for the next
                    // heartbeat.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                        self?.refresh()
                    }
                }
            }
        }
    }

    func setAudioFeedback(_ enabled: Bool) {
        audioFeedbackEnabled = enabled
        pumpManager.setAudioFeedbackEnabled(enabled)
    }

    func setAudioFeedbackForAutomaticDoses(_ enabled: Bool) {
        audioFeedbackForAutomaticDoses = enabled
        pumpManager.setAudioFeedbackForAutomaticDoses(enabled)
    }
}

struct TandemSettingsView: View {
    @ObservedObject var viewModel: TandemSettingsViewModel

    var body: some View {
        Form {
            statusSection
            deliverySection
            remoteBolusSection
            if viewModel.remoteBolusEnabled {
                testDoseSection
            }
            microbolusBasalSection
            soundsSection
            aboutSection
            deleteSection
        }
        .navigationTitle(Text("Tandem t:slim X2"))
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { viewModel.didFinish?() }
            }
        }
        .alert(String(localized: "Enable remote bolus?"), isPresented: $viewModel.showRemoteBolusWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelRemoteBolusEnable() }
            Button(String(localized: "Enable"), role: .destructive) { viewModel.confirmRemoteBolusEnable() }
        } message: {
            Text(
                "Trio will be able to deliver boluses on this pump when you confirm them. Boluses delivered here are in addition to anything Control-IQ doses on the pump. Requires pump software 7.6 with the mobile bolus feature. Only enable this if you understand the risks."
            )
        }
        .alert(String(localized: "Enable microbolus-basal looping?"), isPresented: $viewModel.showMicrobolusWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelMicrobolusEnable() }
            Button(String(localized: "I understand, enable"), role: .destructive) { viewModel.confirmMicrobolusEnable() }
        } message: {
            Text(
                "Trio will deliver ALL basal insulin as a stream of automatic microboluses. You MUST first set the pump's own basal profile to 0 U/hr and turn Control-IQ OFF — otherwise insulin will stack and you could go dangerously low. This disables the pump's built-in safety automation (Control-IQ / Basal-IQ) and relies entirely on Trio. It is experimental and unverified on hardware. Only enable if you fully understand the risk."
            )
        }
        .alert(String(localized: "Deliver 0.001 U test bolus?"), isPresented: $viewModel.showTestDoseConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Deliver")) { viewModel.confirmTestDose() }
        } message: {
            Text(
                "This sends a real 0.001 U bolus to the pump to verify it accepts the smallest possible dose. The amount is negligible, but it is real insulin and will be recorded in the treatment log."
            )
        }
        .alert(String(localized: "Remove pump?"), isPresented: $viewModel.showDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Remove"), role: .destructive) { viewModel.didDeletePump?() }
        } message: {
            Text("Trio will forget this pump. Delivery on the pump itself is not affected.")
        }
    }

    private var soundsSection: some View {
        Section(
            header: Text("Sounds"),
            footer: Text(
                "The t:slim X2 cannot beep on command like an Omnipod, so Trio plays the confirmation sound on this phone instead: one tone when insulin delivery is accepted, another on cancel, suspend, or resume. Automatic doses (SMBs and basal microboluses) are silent unless enabled — with microbolus-basal looping on, they sound every loop cycle."
            )
        ) {
            Toggle(
                String(localized: "Sound on pump changes"),
                isOn: Binding(
                    get: { viewModel.audioFeedbackEnabled },
                    set: { viewModel.setAudioFeedback($0) }
                )
            )
            if viewModel.audioFeedbackEnabled {
                Toggle(
                    String(localized: "Also for automatic doses"),
                    isOn: Binding(
                        get: { viewModel.audioFeedbackForAutomaticDoses },
                        set: { viewModel.setAudioFeedbackForAutomaticDoses($0) }
                    )
                )
            }
        }
    }

    private var statusSection: some View {
        Section(header: Text("Status")) {
            row(String(localized: "Reservoir"), viewModel.state.reservoir > 0
                ? "\(Int(viewModel.state.reservoir))\(viewModel.state.reservoirIsEstimate ? "+" : "") U"
                : "-")
            row(String(localized: "Battery"), viewModel.state.batteryPercent.map { "\($0)%" } ?? "-")
            row(String(localized: "Last sync"), viewModel.lastSyncText)
            HStack {
                Text("Refresh")
                Spacer()
                if viewModel.refreshing {
                    ProgressView()
                } else {
                    Button {
                        viewModel.refresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
    }

    private var deliverySection: some View {
        Section(
            header: Text("Delivery"),
            footer: Text(
                viewModel.microbolusBasalEnabled
                    ? "Microbolus-basal looping is on: Trio delivers all basal as automatic microboluses, driven by the basal rates in Trio's therapy settings. The pump's own basal profile must stay at 0 U/hr with Control-IQ off."
                    : "Basal delivery is managed entirely by the pump\(viewModel.state.controlIQEnabled ? " (Control-IQ is on)" : ""). Trio records what the pump reports but cannot adjust basal on the t:slim X2, so closed loop is unavailable unless microbolus-basal looping is enabled below."
            )
        ) {
            row(
                String(localized: "Current basal"),
                viewModel.state.lastSync == .distantPast ? "-" :
                    String(format: "%.2f U/hr", viewModel.state.currentBasalRate)
            )
            row(
                String(localized: "Profile basal"),
                viewModel.state.lastSync == .distantPast ? "-" :
                    String(format: "%.2f U/hr", viewModel.state.profileBasalRate)
            )
            row(String(localized: "Control-IQ"), viewModel.state.controlIQEnabled
                ? String(localized: "On")
                : String(localized: "Off"))
            if viewModel.state.suspended {
                row(String(localized: "Delivery"), String(localized: "Suspended"))
            }
        }
    }

    private var remoteBolusSection: some View {
        Section(
            header: Text("Remote bolus"),
            footer: viewModel.state.supportsRemoteBolus || viewModel.state.apiVersionMajor == 0
                ? Text("Allows delivering manually confirmed boluses from Trio using the pump's mobile bolus feature.")
                : Text("This pump's software (API \(viewModel.apiVersionText)) does not support remote bolus; software 7.6 is required.")
        ) {
            Toggle(
                String(localized: "Allow remote bolus"),
                isOn: Binding(
                    get: { viewModel.remoteBolusEnabled },
                    set: { viewModel.requestRemoteBolusChange($0) }
                )
            )
            .disabled(!viewModel.state.supportsRemoteBolus && viewModel.state.apiVersionMajor > 0)
        }
    }

    private var testDoseSection: some View {
        Section(
            header: Text("Minimum dose test"),
            footer: Text(
                "Verifies that the pump accepts the smallest dose Trio can command (0.001 U) before relying on fine-grained dosing. Whether the firmware allows a remote bolus below 0.05 U is unverified — a rejection here is harmless and simply means the pump refused the dose."
            )
        ) {
            if viewModel.testDoseInProgress {
                HStack {
                    Text("Testing 0.001 U delivery…")
                    Spacer()
                    ProgressView()
                }
            } else {
                Button {
                    viewModel.requestTestDose()
                } label: {
                    Text("Deliver 0.001 U test bolus")
                }
            }
            if let result = viewModel.testDoseResult {
                HStack(alignment: .top) {
                    Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(result.success ? .green : .red)
                    Text(result.message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var microbolusBasalSection: some View {
        Section(
            header: Text("Microbolus-basal (experimental)"),
            footer: Text(
                "Delivers all basal as automatic microboluses so Trio can close the loop on the t:slim X2. Requires the pump's basal profile set to 0 U/hr and Control-IQ off. Disables the pump's own safety automation. Unverified on hardware — use at your own risk."
            )
        ) {
            Toggle(
                String(localized: "Loop via microbolus-basal"),
                isOn: Binding(
                    get: { viewModel.microbolusBasalEnabled },
                    set: { viewModel.requestMicrobolusChange($0) }
                )
            )
            .disabled(!viewModel.state.supportsRemoteBolus && viewModel.state.apiVersionMajor > 0)

            if viewModel.microbolusBasalEnabled {
                HStack(alignment: .top) {
                    Image(systemName: viewModel.microbolusPreconditionsMet
                        ? "checkmark.circle.fill"
                        : "exclamationmark.triangle.fill")
                        .foregroundColor(viewModel.microbolusPreconditionsMet ? .green : .orange)
                    Text(viewModel.preconditionDetail)
                        .font(.footnote)
                        .foregroundColor(viewModel.microbolusPreconditionsMet ? .secondary : .orange)
                }
            }
        }
    }

    private var aboutSection: some View {
        Section(header: Text("Pump")) {
            row(String(localized: "Serial number"), viewModel.state.pumpSerial.isEmpty ? "-" : viewModel.state.pumpSerial)
            row(String(localized: "Firmware"), viewModel.state.firmwareVersion.isEmpty ? "-" : viewModel.state.firmwareVersion)
            row(String(localized: "API version"), viewModel.apiVersionText)
            row(String(localized: "Insulin"), viewModel.state.insulinType?.brandName ?? "-")
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                viewModel.showDeleteConfirmation = true
            } label: {
                Text("Remove Pump from Trio")
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundColor(.secondary)
        }
    }
}
