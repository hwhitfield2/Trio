import LoopKit
import SwiftUI

final class TandemSettingsViewModel: ObservableObject {
    @Published var refreshing = false
    @Published var remoteBolusEnabled: Bool
    @Published var showRemoteBolusWarning = false
    @Published var remoteBasalEnabled: Bool
    @Published var showRemoteBasalWarning = false
    @Published var microbolusBasalEnabled: Bool
    @Published var showMicrobolusWarning = false
    @Published var showDeleteConfirmation = false
    @Published var cartridgeChangeEnabled: Bool = false
    @Published var showCartridgeWarning = false
    @Published var showCartridgeSheet = false
    @Published var audioFeedbackEnabled: Bool
    @Published var audioFeedbackForAutomaticDoses: Bool
    @Published var showTestDoseConfirmation = false
    @Published var testDoseInProgress = false
    @Published var testDoseResult: (success: Bool, message: String)?
    @Published var testDoseUnits: Double = TandemSettingsViewModel.testDoseOptions[0]

    let pumpManager: TandemPumpManager

    var didFinish: (() -> Void)?
    var didDeletePump: (() -> Void)?

    init(pumpManager: TandemPumpManager) {
        self.pumpManager = pumpManager
        remoteBolusEnabled = pumpManager.state.remoteBolusEnabled
        remoteBasalEnabled = pumpManager.state.remoteBasalEnabled
        cartridgeChangeEnabled = pumpManager.state.cartridgeChangeEnabled
        microbolusBasalEnabled = pumpManager.state.microbolusBasalEnabled
        audioFeedbackEnabled = pumpManager.state.audioFeedbackEnabled
        audioFeedbackForAutomaticDoses = pumpManager.state.audioFeedbackForAutomaticDoses
    }

    var state: TandemPumpState { pumpManager.state }

    var model: TandemPumpModel { state.pumpModel }

    /// True on a pump whose firmware implements the temp-rate/suspend/resume
    /// opcodes, i.e. a Mobi.
    var supportsNativeBasal: Bool { state.supportsNativeBasalControl }

    /// Whether a native temp basal could be sent right now, and if not, why.
    var nativeBasalReadinessDetail: String {
        if state.lastSync == .distantPast {
            return String(localized: "Waiting for a status sync from the pump…")
        }
        var problems: [String] = []
        if state.controlIQEnabled {
            problems.append(String(localized: "Control-IQ is on (must be off)"))
        }
        if state.profileBasalRate < TandemPumpManager.minimumProfileBasalForTempRate {
            problems.append(String(localized: "the pump's basal profile is 0 U/hr (must be non-zero)"))
        }
        if problems.isEmpty {
            let maxRate = state.profileBasalRate * Double(TandemTempRateLimits.maxPercent) / 100
            let maxRateText = String(format: "%.2f", maxRate)
            let profileText = String(format: "%.2f", state.profileBasalRate)
            return String(
                localized: "Ready. Trio can set 0 to \(maxRateText) U/hr right now, which is 0 to 250 percent of the pump's \(profileText) U/hr profile rate."
            )
        }
        return problems.joined(separator: "; ")
    }

    var activeTempBasalText: String? {
        guard let temp = state.activeTempBasal, temp.isActive() else { return nil }
        let formatter = RelativeDateTimeFormatter()
        let rateText = String(format: "%.2f", temp.unitsPerHour)
        let percentText = "\(temp.percent)%"
        let endsText = formatter.localizedString(for: temp.endDate, relativeTo: Date.now)
        return String(localized: "\(rateText) U/hr (\(percentText)), ends \(endsText)")
    }

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

    func requestRemoteBasalChange(_ enabled: Bool) {
        if enabled {
            showRemoteBasalWarning = true
        } else {
            remoteBasalEnabled = false
            pumpManager.setRemoteBasalEnabled(false)
        }
    }

    func confirmRemoteBasalEnable() {
        remoteBasalEnabled = true
        pumpManager.setRemoteBasalEnabled(true)
    }

    func cancelRemoteBasalEnable() {
        remoteBasalEnabled = false
    }

    func requestCartridgeChangeEnabled(_ enabled: Bool) {
        if enabled {
            showCartridgeWarning = true
        } else {
            cartridgeChangeEnabled = false
            pumpManager.setCartridgeChangeEnabled(false)
        }
    }

    func confirmCartridgeChangeEnable() {
        cartridgeChangeEnabled = true
        pumpManager.setCartridgeChangeEnabled(true)
    }

    func cancelCartridgeChangeEnable() {
        cartridgeChangeEnabled = false
    }

    var cartridgeChangeInProgress: Bool { state.cartridgeChangeInProgress }

    /// Created once and reused, so presenting the sheet does not spawn a new
    /// view model (and a new status observer) on every redraw.
    lazy var cartridgeViewModel = TandemCartridgeChangeViewModel(pumpManager: pumpManager)

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

    /// Candidate test amounts. The remote-bolus floor is settled — firmware
    /// 7.6.0.1 accepts 0.05 U and rejects smaller amounts (status 1 at
    /// initiate), and the driver's floor is pinned there (sub-floor commands
    /// are refused locally, so they are not offered). What remains worth
    /// probing is milliunit resolution ABOVE the floor: whether the pump
    /// accepts and actually delivers e.g. 0.051 U, which fine-grained
    /// microbolus dosing relies on.
    static let testDoseOptions: [Double] = [0.05, 0.051, 0.055, 0.06, 0.1]

    func formatTestDose(_ units: Double) -> String {
        String(format: "%g", units)
    }

    func requestTestDose() {
        testDoseResult = nil
        showTestDoseConfirmation = true
    }

    /// Deliver a single small bolus through the normal remote-bolus path to
    /// find out whether the pump accepts a dose that small. The regular
    /// enactBolus flow is used on purpose: the test exercises the exact
    /// permission → initiate → reconcile sequence production dosing uses, and
    /// the delivered insulin is recorded in the treatment log like any bolus.
    func confirmTestDose() {
        let units = testDoseUnits
        let amountText = formatTestDose(units)
        testDoseInProgress = true
        pumpManager.enactBolus(units: units, activationType: .manualNoRecommendation) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.testDoseInProgress = false
                if let error {
                    if case .uncertainDelivery = error {
                        // Not a rejection: communication dropped mid-command, so
                        // the pump may or may not have delivered. Says nothing
                        // about whether doses this small are accepted.
                        self.testDoseResult = (
                            success: false,
                            message: String(
                                localized: "Communication was lost mid-command, so it is unknown whether the \(amountText) U test bolus was delivered — this does not tell us whether the pump accepts it. Check the pump's bolus history, then try again."
                            )
                        )
                    } else {
                        self.testDoseResult = (
                            success: false,
                            message: String(
                                localized: "The pump did not accept the \(amountText) U test bolus: \(error.localizedDescription)"
                            )
                        )
                    }
                } else {
                    self.testDoseResult = (
                        success: true,
                        message: String(
                            localized: "The pump accepted the \(amountText) U test bolus. It is recorded in Trio's treatment log — confirm in the pump's own bolus history that \(amountText) U was actually delivered."
                        )
                    )
                    // A tiny bolus completes almost instantly; refresh shortly
                    // after so the delivery reconciles and the single-bolus
                    // gate releases without waiting for the next heartbeat.
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
            if viewModel.supportsNativeBasal {
                remoteBasalSection
            } else {
                microbolusBasalSection
            }
            cartridgeSection
            soundsSection
            aboutSection
            deleteSection
        }
        .sheet(isPresented: $viewModel.showCartridgeSheet) {
            NavigationView {
                TandemCartridgeChangeView(viewModel: viewModel.cartridgeViewModel)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { viewModel.showCartridgeSheet = false }
                    }
                }
            }
        }
        .navigationTitle(Text(viewModel.model.localizedTitle))
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
        .alert(String(localized: "Let Trio control basal delivery?"), isPresented: $viewModel.showRemoteBasalWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelRemoteBasalEnable() }
            Button(String(localized: "I understand, enable"), role: .destructive) { viewModel.confirmRemoteBasalEnable() }
        } message: {
            Text(
                "Trio will set temp basal rates on the pump and can suspend and resume delivery, which is what lets it close the loop. You MUST turn the pump's own Control-IQ OFF first — two systems adjusting basal at once is unsafe. The pump also needs a non-zero basal profile, because Tandem temp rates are a percentage (0-250%) of the profile rate. Only enable this if you understand the risks."
            )
        }
        .alert(String(localized: "Change cartridges from Trio?"), isPresented: $viewModel.showCartridgeWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelCartridgeChangeEnable() }
            Button(String(localized: "I understand, enable"), role: .destructive) { viewModel.confirmCartridgeChangeEnable() }
        } message: {
            Text(
                "Trio will be able to put the pump into cartridge-change mode, fill the tubing and prime the cannula. Filling and priming push real insulin, and Trio cannot see whether your infusion set is on your body — it can only ask you. Get that wrong and insulin goes somewhere it should not. This flow has not been tested against a real pump. Doing the change on the pump itself is always the safer option."
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
        .alert(String(localized: "Deliver test bolus?"), isPresented: $viewModel.showTestDoseConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Deliver")) { viewModel.confirmTestDose() }
        } message: {
            Text(
                "This sends a real \(viewModel.formatTestDose(viewModel.testDoseUnits)) U bolus to the pump to check whether it accepts a dose this small. It is real insulin and will be recorded in the treatment log."
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
                "Tandem pumps cannot beep on command like an Omnipod, so Trio plays the confirmation sound on this phone instead: one tone when insulin delivery is accepted, another on cancel, suspend, or resume. Automatic doses (SMBs and basal microboluses) are silent unless enabled — with microbolus-basal looping on, they sound every loop cycle."
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
            row(
                String(localized: "Reservoir"),
                viewModel.state.reservoir > 0
                    ? "\(Int(viewModel.state.reservoir))\(viewModel.state.reservoirIsEstimate ? "+" : "") U"
                    : "-"
            )
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

    private var deliveryFooterText: String {
        if viewModel.supportsNativeBasal {
            return viewModel.remoteBasalEnabled
                ? String(
                    localized: "Trio is controlling basal delivery with the pump's own temp rate command. Rates are sent as a percentage of the pump's active basal profile, so the profile must stay non-zero and Control-IQ must stay off."
                )
                : String(
                    localized: "Basal delivery is managed entirely by the pump\(viewModel.state.controlIQEnabled ? " (Control-IQ is on)" : ""). Turn on remote basal control below to let Trio close the loop with this Mobi."
                )
        }
        return viewModel.microbolusBasalEnabled
            ? String(
                localized: "Microbolus-basal looping is on: Trio delivers all basal as automatic microboluses, driven by the basal rates in Trio's therapy settings. The pump's own basal profile must stay at 0 U/hr with Control-IQ off."
            )
            : String(
                localized: "Basal delivery is managed entirely by the pump\(viewModel.state.controlIQEnabled ? " (Control-IQ is on)" : ""). Trio records what the pump reports but cannot adjust basal on the t:slim X2, so closed loop is unavailable unless microbolus-basal looping is enabled below."
            )
    }

    private var deliverySection: some View {
        Section(
            header: Text("Delivery"),
            footer: Text(deliveryFooterText)
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
            row(
                String(localized: "Control-IQ"),
                viewModel.state.controlIQEnabled
                    ? String(localized: "On")
                    : String(localized: "Off")
            )
            if let tempBasal = viewModel.activeTempBasalText {
                row(String(localized: "Temp basal"), tempBasal)
            }
            if viewModel.state.suspended {
                row(String(localized: "Delivery"), String(localized: "Suspended"))
            }
        }
    }

    private var remoteBasalSection: some View {
        Section(
            header: Text("Closed loop"),
            footer: Text(
                "Lets Trio set temp basal rates and suspend or resume delivery on the Mobi — the pump commands Trio needs to close the loop. Requires the pump's Control-IQ to be off and a non-zero basal profile, since Tandem temp rates are a percentage (0-250%) of the profile rate."
            )
        ) {
            Toggle(
                String(localized: "Let Trio control basal"),
                isOn: Binding(
                    get: { viewModel.remoteBasalEnabled },
                    set: { viewModel.requestRemoteBasalChange($0) }
                )
            )

            if viewModel.remoteBasalEnabled {
                let ready = !viewModel.state.controlIQEnabled
                    && viewModel.state.profileBasalRate >= TandemPumpManager.minimumProfileBasalForTempRate
                    && viewModel.state.lastSync != .distantPast
                HStack(alignment: .top) {
                    Image(systemName: ready ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundColor(ready ? .green : .orange)
                    Text(viewModel.nativeBasalReadinessDetail)
                        .font(.footnote)
                        .foregroundColor(ready ? .secondary : .orange)
                }
            }
        }
    }

    private var remoteBolusSection: some View {
        Section(
            header: Text("Remote bolus"),
            footer: viewModel.state.supportsRemoteBolus || viewModel.state.apiVersionMajor == 0
                ? Text("Allows delivering manually confirmed boluses from Trio using the pump's mobile bolus feature.")
                :
                Text(
                    "This pump's software (API \(viewModel.apiVersionText)) does not support remote bolus; software 7.6 is required."
                )
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
                "The pump's remote-bolus minimum is 0.05 U (confirmed on firmware 7.6.0.1; smaller doses are rejected). Use this to verify 0.05 U works on your pump, and to probe whether milliunit amounts above the floor (like 0.051 U) are accepted and delivered exactly — check the pump's own bolus history for the delivered amount. A rejection is harmless."
            )
        ) {
            Picker(String(localized: "Test amount"), selection: $viewModel.testDoseUnits) {
                ForEach(TandemSettingsViewModel.testDoseOptions, id: \.self) { amount in
                    Text("\(viewModel.formatTestDose(amount)) U").tag(amount)
                }
            }
            .disabled(viewModel.testDoseInProgress)
            if viewModel.testDoseInProgress {
                HStack {
                    Text("Testing \(viewModel.formatTestDose(viewModel.testDoseUnits)) U delivery…")
                    Spacer()
                    ProgressView()
                }
            } else {
                Button {
                    viewModel.requestTestDose()
                } label: {
                    Text("Deliver \(viewModel.formatTestDose(viewModel.testDoseUnits)) U test bolus")
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
                    Image(
                        systemName: viewModel.microbolusPreconditionsMet
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .foregroundColor(viewModel.microbolusPreconditionsMet ? .green : .orange)
                    Text(viewModel.preconditionDetail)
                        .font(.footnote)
                        .foregroundColor(viewModel.microbolusPreconditionsMet ? .secondary : .orange)
                }
            }
        }
    }

    private var cartridgeSection: some View {
        Section(
            header: Text("Cartridge"),
            footer: Text(
                "Lets Trio walk through loading a new cartridge, filling the tubing and — on a Mobi — priming the cannula. Delivery is stopped and Trio will not loop for the whole change. Untested against a real pump; changing the cartridge on the pump itself is the safer option."
            )
        ) {
            Toggle(
                String(localized: "Allow cartridge changes"),
                isOn: Binding(
                    get: { viewModel.cartridgeChangeEnabled },
                    set: { viewModel.requestCartridgeChangeEnabled($0) }
                )
            )
            if viewModel.cartridgeChangeInProgress {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                    Text("A cartridge change is in progress. Trio is not delivering insulin until it is finished or cancelled.")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
            if viewModel.cartridgeChangeEnabled {
                Button {
                    viewModel.showCartridgeSheet = true
                } label: {
                    Text(viewModel.cartridgeChangeInProgress ? "Resume cartridge change" : "Change cartridge…")
                }
            }
        }
    }

    private var aboutSection: some View {
        Section(header: Text("Pump")) {
            row(String(localized: "Model"), viewModel.model.localizedTitle)
            row(
                String(localized: "Pairing"),
                viewModel.state.pairingCodeType == .jpake6
                    ? String(localized: "6-digit code")
                    : String(localized: "16-character code")
            )
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
