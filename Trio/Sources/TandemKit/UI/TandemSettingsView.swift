import Combine
import LoopKit
import SwiftUI

/// Drives the pump screen.
///
/// It observes the driver rather than sampling it: a Mobi has no display of its
/// own, so this screen is where its reservoir, its alarms and its suspend state
/// actually appear, and a screen that only updated when the user pressed a
/// refresh button was showing yesterday's pump.
final class TandemSettingsViewModel: ObservableObject, PumpManagerStatusObserver {
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
    @Published var acknowledgingAlarms = false
    @Published var alarmErrorMessage: String?
    @Published var glucoseAnnunciationEnabled: Bool
    @Published var testingAnnunciation: TandemGlucoseAlarmKind?
    @Published var annunciationResult: (success: Bool, message: String)?

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
        glucoseAnnunciationEnabled = pumpManager.state.glucoseAnnunciationEnabled
        pumpManager.addStatusObserver(self, queue: .main)
    }

    deinit {
        pumpManager.removeStatusObserver(self)
    }

    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        // The status payload carries almost none of what this screen shows, so
        // it is only used as a "something changed" tick; the values are read
        // straight off the driver's state.
        objectWillChange.send()
    }

    var state: TandemPumpState { pumpManager.state }

    var model: TandemPumpModel { state.pumpModel }

    var isMobi: Bool { model == .mobi }

    /// Where the user can look when Trio is not the right place. A Mobi has no
    /// screen, so "on the pump itself" is not somewhere they can go.
    var elsewhereName: String {
        isMobi ? String(localized: "the Tandem Mobi app") : String(localized: "the pump itself")
    }

    /// True while the phone actually has a Bluetooth link to the pump. Both
    /// gaining and losing the link end in `notifyStateDidChange`, so this
    /// redraws with the rest of the screen.
    var isConnected: Bool { pumpManager.bluetooth.isConnected }

    /// True on a pump whose firmware implements the temp-rate/suspend/resume
    /// opcodes, i.e. a Mobi.
    var supportsNativeBasal: Bool { state.supportsNativeBasalControl }

    // MARK: - Status

    var headline: TandemHeadlineStatus { state.headlineStatus }

    var linkPill: (text: String, tone: TandemTone, symbol: String) {
        if !isConnected {
            return (
                String(localized: "Not connected"),
                .caution,
                "antenna.radiowaves.left.and.right.slash"
            )
        }
        return (String(localized: "Connected"), .ok, "dot.radiowaves.left.and.right")
    }

    var syncPill: (text: String, tone: TandemTone) {
        guard state.hasEverSynced else {
            return (String(localized: "Never synced"), .caution)
        }
        return (
            String(localized: "Synced \(TimeAgoFormatter.minutesAgo(from: state.lastSync)) ago"),
            state.syncTone
        )
    }

    var lastSyncText: String { state.lastSyncDescription }

    var apiVersionText: String {
        guard state.apiVersionMajor > 0 else { return "-" }
        return "\(state.apiVersionMajor).\(state.apiVersionMinor)"
    }

    var activeTempBasalText: String? {
        guard let temp = state.activeTempBasal, temp.isActive() else { return nil }
        let rateText = TandemPumpState.rateText(temp.unitsPerHour)
        let endsText = TandemPumpState.relativeDateFormatter.localizedString(
            for: temp.endDate,
            relativeTo: Date.now
        )
        return String(localized: "\(rateText) U/hr (\(temp.percent)%), ends \(endsText)")
    }

    /// A battery glyph that matches the reading, rather than a fixed three-
    /// quarters full whatever the pump says.
    var batterySymbol: String {
        if state.batteryCharging { return "battery.100.bolt" }
        guard let percent = state.batteryPercent else { return "battery.50" }
        switch percent {
        case ..<13: return "battery.0"
        case ..<38: return "battery.25"
        case ..<63: return "battery.50"
        case ..<88: return "battery.75"
        default: return "battery.100"
        }
    }

    /// Basal Trio has accrued but not yet pulsed, in microbolus-basal mode. It
    /// exists in the driver and has never been visible: a user watching a
    /// stretch with no delivery has no other way to tell "nothing is owed" from
    /// "something is owed and stuck".
    var owedBasalText: String? {
        guard state.basalControlMode == .microbolus, state.owedBasalInsulin > 0 else { return nil }
        return String(localized: "\(TandemPumpState.unitsText(state.owedBasalInsulin)) U pending")
    }

    // MARK: - Alarms

    var alarmNames: String? { state.activeAlarmNames }
    var acknowledgeableAlarmNames: String? { state.acknowledgeableAlarmNames }
    var unacknowledgeableAlarmNames: String? { state.unacknowledgeableAlarmNames }
    var alertNames: String? { state.activeAlertNames }

    /// What the alarm card says, in the terms of the pump the user actually has
    /// and of whether Trio can do anything about this particular alarm.
    var alarmExplanation: String {
        let opening = String(
            localized: "The pump has stopped insulin and will refuse new commands until this is acknowledged."
        )
        if acknowledgeableAlarmNames != nil {
            return isMobi
                ? String(localized: "\(opening) A Mobi has no screen of its own, so Trio is where you clear it.")
                : String(localized: "\(opening) You can clear it here or on the pump itself.")
        }
        return isMobi
            ? String(localized: "\(opening) This one is not Trio's to clear — use the Tandem Mobi app.")
            : String(localized: "\(opening) This one is not Trio's to clear — use the pump itself.")
    }

    func acknowledgeAlarms() {
        acknowledgingAlarms = true
        alarmErrorMessage = nil
        // Alarms only from here: the leftover "incomplete load" alerts are the
        // pump's reason for refusing to resume, and clearing them belongs to
        // the cartridge flow that is actually finishing the load.
        pumpManager.acknowledgeCartridgeAlarms(includingLoadAlerts: false) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.acknowledgingAlarms = false
                self.alarmErrorMessage = error?.localizedDescription
                if error == nil {
                    TandemHaptics.success()
                } else {
                    TandemHaptics.failure()
                }
                self.objectWillChange.send()
            }
        }
    }

    // MARK: - Refresh

    func refresh(completion: (() -> Void)? = nil) {
        refreshing = true
        pumpManager.refreshPumpData { [weak self] _ in
            DispatchQueue.main.async {
                self?.refreshing = false
                self?.objectWillChange.send()
                completion?()
            }
        }
    }

    @MainActor func refreshAsync() async {
        await withCheckedContinuation { continuation in
            refresh { continuation.resume() }
        }
    }

    // MARK: - Opt-ins

    /// The firmware requirement is a t:slim X2 concern — every Mobi has the
    /// mobile bolus feature — so a Mobi user is not sent looking for a version
    /// number that does not apply to them.
    var remoteBolusWarningText: String {
        let common = String(
            localized: "Trio will be able to deliver boluses on this pump when you confirm them. Boluses delivered here are in addition to anything Control-IQ doses on the pump."
        )
        let closing = String(localized: "Only enable this if you understand the risks.")
        return isMobi
            ? String(localized: "\(common) \(closing)")
            : String(
                localized: "\(common) Requires pump software 7.6 with the mobile bolus feature. \(closing)"
            )
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

    func confirmRemoteBasalEnable() {
        remoteBasalEnabled = true
        microbolusBasalEnabled = false
        pumpManager.setRemoteBasalEnabled(true)
        objectWillChange.send()
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

    var basalControlMode: TandemBasalControlMode { state.basalControlMode }

    var basalControlChecks: [TandemReadinessCheck] { state.basalControlChecks }

    var basalControlIsReady: Bool { state.basalControlIsReady }

    /// Modes this pump can actually offer. Only the Mobi has native temp rates,
    /// and microbolus-basal needs remote bolus, which older t:slim X2 software
    /// does not have.
    var availableBasalModes: [TandemBasalControlMode] {
        var modes: [TandemBasalControlMode] = [.none]
        if supportsNativeBasal {
            modes.append(.nativeTempRate)
        }
        if state.supportsRemoteBolus || state.apiVersionMajor == 0 {
            modes.append(.microbolus)
        }
        // Whatever is actually running has to be selectable, or the picker
        // renders with nothing chosen — a pump identified as older after the
        // mode was set would otherwise hide the mode it is still using.
        if !modes.contains(basalControlMode) {
            modes.append(basalControlMode)
        }
        return modes
    }

    func basalModeTitle(_ mode: TandemBasalControlMode) -> String {
        switch mode {
        case .none: return String(localized: "Pump manages basal")
        case .nativeTempRate: return String(localized: "Trio sets temp rates")
        case .microbolus: return String(localized: "Trio delivers basal as microboluses")
        }
    }

    /// One line on what picking a mode actually means, shown under the picker
    /// rather than left in a footer the user reads after choosing.
    func basalModeSummary(_ mode: TandemBasalControlMode) -> String {
        switch mode {
        case .none:
            return supportsNativeBasal
                ? String(localized: "The pump runs its own basal and Control-IQ. Trio monitors and does not close the loop.")
                : String(localized: "The pump runs its own basal and Control-IQ. Trio monitors it.")
        case .nativeTempRate:
            return String(
                localized: "Trio sets real temp rates on the pump. A Tandem temp rate is a whole percentage of the pump's own basal profile, capped at 250%, so the profile must stay non-zero."
            )
        case .microbolus:
            return String(
                localized: "Trio delivers all basal as small automatic boluses at milliunit resolution, with no 250% ceiling. The pump's own basal profile must be 0 U/hr and its safety automation is off."
            )
        }
    }

    /// Applying a mode goes through the manager so the two opt-ins can never
    /// both end up on, and so a temp rate left running gets stopped.
    func requestBasalMode(_ mode: TandemBasalControlMode) {
        switch mode {
        case .none:
            pumpManager.setMicrobolusBasalEnabled(false)
            pumpManager.setRemoteBasalEnabled(false)
            remoteBasalEnabled = false
            microbolusBasalEnabled = false
        case .nativeTempRate:
            showRemoteBasalWarning = true
        case .microbolus:
            showMicrobolusWarning = true
        }
        objectWillChange.send()
    }

    /// Created once and reused, so presenting the sheet does not spawn a new
    /// view model (and a new status observer) on every redraw.
    lazy var cartridgeViewModel = TandemCartridgeChangeViewModel(pumpManager: pumpManager)

    func confirmMicrobolusEnable() {
        microbolusBasalEnabled = true
        remoteBolusEnabled = true
        remoteBasalEnabled = false
        pumpManager.setMicrobolusBasalEnabled(true)
        objectWillChange.send()
    }

    func cancelMicrobolusEnable() {
        microbolusBasalEnabled = false
    }

    // MARK: - Minimum dose test

    /// Candidate test amounts. The remote-bolus floor is settled — firmware
    /// 7.6.0.1 accepts 0.05 U and rejects smaller amounts (status 1 at
    /// initiate), and the driver's floor is pinned there (sub-floor commands
    /// are refused locally, so they are not offered). What remains worth
    /// probing is milliunit resolution ABOVE the floor: whether the pump
    /// accepts and actually delivers e.g. 0.051 U, which fine-grained
    /// microbolus dosing relies on.
    static let testDoseOptions: [Double] = [0.05, 0.051, 0.055, 0.06, 0.1]

    var testDoseFooterText: String {
        String(
            localized: "The pump's remote-bolus minimum is 0.05 U; smaller doses are rejected. Use this to verify 0.05 U works on your pump, and to probe whether milliunit amounts above the floor (like 0.051 U) are accepted and delivered exactly — check the bolus history in \(elsewhereName) for the delivered amount. A rejection is harmless."
        )
    }

    func formatTestDose(_ units: Double) -> String {
        TandemPumpState.doseText(units)
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
                    TandemHaptics.failure()
                    if case .uncertainDelivery = error {
                        // Not a rejection: communication dropped mid-command, so
                        // the pump may or may not have delivered. Says nothing
                        // about whether doses this small are accepted.
                        self.testDoseResult = (
                            success: false,
                            message: String(
                                localized: "Communication was lost mid-command, so it is unknown whether the \(amountText) U test bolus was delivered — this does not tell us whether the pump accepts it. Check the bolus history in \(self.elsewhereName), then try again."
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
                    TandemHaptics.success()
                    self.testDoseResult = (
                        success: true,
                        message: String(
                            localized: "The pump accepted the \(amountText) U test bolus. It is recorded in Trio's treatment log — confirm in \(self.elsewhereName) that \(amountText) U was actually delivered."
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

    // MARK: - Glucose alarms on the pump

    func setGlucoseAnnunciation(_ enabled: Bool) {
        glucoseAnnunciationEnabled = enabled
        annunciationResult = nil
        pumpManager.setGlucoseAnnunciationEnabled(enabled)
    }

    /// True once this pump has answered a buzz with a refusal. Trio stops
    /// asking until the app restarts or the user presses test.
    var annunciationRefused: Bool { state.annunciationRefusedByPump }

    func describePattern(_ kind: TandemGlucoseAlarmKind) -> String {
        let pattern = TandemAnnunciationPattern.pattern(for: kind)
        let seconds = TandemPumpState.doseText(pattern.gap)
        return String(localized: "\(pattern.pulses) buzzes, \(seconds) s apart")
    }

    /// Play one of the patterns on demand. The point of the test is that the
    /// user can tell the two apart before they have to recognise one through a
    /// pocket at 3am — and, because the command is unverified, that they can
    /// find out whether their pump answers it at all.
    func testAnnunciation(_ kind: TandemGlucoseAlarmKind) {
        testingAnnunciation = kind
        annunciationResult = nil
        pumpManager.testAnnunciation(kind) { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.testingAnnunciation = nil
                if let error {
                    TandemHaptics.failure()
                    self.annunciationResult = (false, error.localizedDescription)
                } else {
                    TandemHaptics.success()
                    // Deliberately does not claim it worked. The pump answering
                    // "accepted" says nothing about whether anything was
                    // audible — PlaySound has no volume of its own — and
                    // reporting success for a silent pump is how someone ends
                    // up trusting an alarm that never reaches them.
                    self.annunciationResult = (
                        true,
                        String(
                            localized: "The pump accepted the command and should be playing the \(kind.localizedTitle.lowercased()) pattern: \(self.describePattern(kind)). If you felt and heard nothing, the pump decided that, not Trio — this command has no volume of its own and follows the pump's own Sound setting. Check it in \(self.elsewhereName)."
                        )
                    )
                }
                self.objectWillChange.send()
            }
        }
    }
}

struct TandemSettingsView: View {
    @ObservedObject var viewModel: TandemSettingsViewModel

    /// "Synced 2 m ago", the sync colour and a temp basal's countdown all move
    /// with the clock, not with anything the driver publishes, so the screen
    /// ticks them along itself rather than freezing at whatever it said when it
    /// opened.
    @State private var ticker = Timer.publish(every: 30, on: .main, in: .common).autoconnect()
    @State private var now = Date.now

    var body: some View {
        List {
            Group {
                notificationSections
                statusSection
                deliverySection
                basalModeSection
            }
            Group {
                remoteBolusSection
                cartridgeSection
                glucoseAlarmSection
                soundsSection
                // A section that pushes real insulin belongs with the
                // diagnostics, not above the settings that decide how the pump
                // loops.
                if viewModel.remoteBolusEnabled {
                    testDoseSection
                }
                aboutSection
                deleteSection
            }
        }
        .refreshable {
            await viewModel.refreshAsync()
        }
        .tandemScreenBackground()
        .onReceive(ticker) { now = $0 }
        .sheet(isPresented: $viewModel.showCartridgeSheet) {
            NavigationStack {
                TandemCartridgeChangeView(viewModel: viewModel.cartridgeViewModel)
                    // A swipe-down while insulin is stopped and the pump is
                    // half-loaded is the one dismissal that must be deliberate.
                    .interactiveDismissDisabled(viewModel.cartridgeChangeInProgress)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button(
                                viewModel.cartridgeChangeInProgress
                                    ? String(localized: "Leave open")
                                    : String(localized: "Done")
                            ) {
                                viewModel.showCartridgeSheet = false
                            }
                        }
                    }
            }
        }
        .navigationTitle(Text(viewModel.model.localizedTitle))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    viewModel.refresh()
                } label: {
                    if viewModel.refreshing {
                        ProgressView()
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(viewModel.refreshing)
                .accessibilityLabel(String(localized: "Read the pump now"))
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(String(localized: "Done")) { viewModel.didFinish?() }
            }
        }
        .alert(String(localized: "Enable remote bolus?"), isPresented: $viewModel.showRemoteBolusWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelRemoteBolusEnable() }
            Button(String(localized: "Enable"), role: .destructive) { viewModel.confirmRemoteBolusEnable() }
        } message: {
            Text(viewModel.remoteBolusWarningText)
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
                "Trio will be able to put the pump into cartridge-change mode, fill the tubing and prime the cannula. Filling and priming push real insulin, and Trio cannot see whether your infusion set is on your body — it can only ask you. Get that wrong and insulin goes somewhere it should not. This flow has not been tested against a real pump. Doing the change the usual way, in \(viewModel.elsewhereName), is always the safer option."
            )
        }
        .alert(String(localized: "Enable microbolus-basal looping?"), isPresented: $viewModel.showMicrobolusWarning) {
            Button(String(localized: "Cancel"), role: .cancel) { viewModel.cancelMicrobolusEnable() }
            Button(String(localized: "I understand, enable"), role: .destructive) { viewModel.confirmMicrobolusEnable() }
        } message: {
            Text(
                "Trio will deliver ALL basal insulin as a stream of automatic microboluses, and will turn on remote bolus to do it. You MUST first set the pump's own basal profile to 0 U/hr and turn Control-IQ OFF — otherwise insulin will stack and you could go dangerously low. This disables the pump's built-in safety automation (Control-IQ / Basal-IQ) and relies entirely on Trio. It is experimental and unverified on hardware. Only enable if you fully understand the risk."
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

    // MARK: - Alarms

    @ViewBuilder private var notificationSections: some View {
        if viewModel.alarmNames != nil {
            alarmSection
        }
        if viewModel.alertNames != nil {
            alertSection
        }
    }

    /// Step zero, and above everything else on purpose. An alarming Tandem has
    /// already stopped insulin and refuses every new command, and on a Mobi
    /// this screen is the only place the alarm can be seen or cleared.
    private var alarmSection: some View {
        Section {
            TandemCallout(
                title: viewModel.alarmNames ?? String(localized: "Pump alarm"),
                message: viewModel.alarmExplanation,
                tone: .critical,
                symbolName: "bell.badge.fill"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if let names = viewModel.acknowledgeableAlarmNames {
                        TandemActionButton(
                            title: String(localized: "Acknowledge \(names)"),
                            systemImage: "checkmark.circle",
                            isBusy: viewModel.acknowledgingAlarms,
                            busyTitle: String(localized: "Acknowledging…")
                        ) {
                            viewModel.acknowledgeAlarms()
                        }
                    }
                    if let others = viewModel.unacknowledgeableAlarmNames {
                        Text(
                            "Trio does not clear \(others). Only the cartridge-related alarms are Trio's to acknowledge — use the Tandem app or contact Tandem for the rest."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    if let error = viewModel.alarmErrorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(Color.loopRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Alarm").glassCaption()
        }
        .tandemRowBackground()
    }

    /// Alerts are the pump's advisory tier: they do not stop delivery, so they
    /// sit below the alarm card and never offer a clear-all button.
    private var alertSection: some View {
        Section {
            TandemCallout(
                title: viewModel.alertNames ?? String(localized: "Pump alert"),
                message: String(
                    localized: "An alert is a warning, not a stop: unlike an alarm it does not by itself hold insulin. Leftover \"incomplete\" alerts from an interrupted cartridge load are cleared by finishing the change."
                ),
                tone: .caution,
                symbolName: "exclamationmark.bubble.fill"
            )
        } header: {
            Text("Alert").glassCaption()
        }
        .tandemRowBackground()
    }

    // MARK: - Status

    private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: viewModel.headline.symbolName)
                        .foregroundStyle(viewModel.headline.tone.color)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.headline.title)
                            .font(.headline)
                        Text(viewModel.headline.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)

                HStack(spacing: 8) {
                    TandemStatusPill(
                        text: viewModel.linkPill.text,
                        tone: viewModel.linkPill.tone,
                        symbolName: viewModel.linkPill.symbol
                    )
                    TandemStatusPill(
                        text: viewModel.syncPill.text,
                        tone: viewModel.syncPill.tone,
                        symbolName: "arrow.triangle.2.circlepath"
                    )
                }

                Divider().overlay(Color.primary.opacity(0.08))

                HStack(alignment: .top, spacing: 12) {
                    TandemMetricTile(
                        label: String(localized: "Insulin left"),
                        value: viewModel.state.reservoirDescription,
                        caption: reservoirCaption,
                        systemImage: "cross.vial.fill",
                        tone: viewModel.state.reservoirTone
                    )
                    TandemMetricTile(
                        label: String(localized: "Battery"),
                        value: viewModel.state.batteryDescription,
                        systemImage: viewModel.batterySymbol,
                        tone: viewModel.state.batteryTone
                    )
                    TandemMetricTile(
                        label: String(localized: "Delivering"),
                        value: viewModel.state.deliveryDescription,
                        caption: viewModel.owedBasalText ?? viewModel.state.deliveryCaption,
                        systemImage: "drop.fill",
                        tone: viewModel.state.deliveryTone
                    )
                }

                if let fraction = viewModel.state.reservoirFraction {
                    TandemLevelBar(fraction: fraction, tone: viewModel.state.reservoirTone)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Pump status").glassCaption()
        } footer: {
            Text(
                "Trio reads the pump every few minutes and whenever the pump reports a change. Pull down to read it now."
            )
        }
        .tandemRowBackground()
    }

    /// The Mobi carries 200 U and the t:slim X2 300, and the pump reports whole
    /// units with its own estimate flag — so the number alone does not say how
    /// full the cartridge is.
    private var reservoirCaption: String? {
        guard viewModel.state.hasEverSynced else { return nil }
        let capacity = Int(viewModel.state.reservoirCapacity)
        return String(localized: "of \(capacity) U")
    }

    // MARK: - Delivery

    private var deliverySection: some View {
        Section {
            TandemInfoRow(
                label: String(localized: "Current basal"),
                value: viewModel.state.hasEverSynced
                    ? String(localized: "\(TandemPumpState.rateText(viewModel.state.currentBasalRate)) U/hr")
                    : "—"
            )
            TandemInfoRow(
                label: String(localized: "Profile basal"),
                value: viewModel.state.hasEverSynced
                    ? String(localized: "\(TandemPumpState.rateText(viewModel.state.profileBasalRate)) U/hr")
                    : "—"
            )
            TandemInfoRow(
                label: String(localized: "Control-IQ"),
                value: viewModel.state.controlIQEnabled
                    ? String(localized: "On")
                    : String(localized: "Off"),
                tone: viewModel.state.controlIQEnabled && viewModel.basalControlMode != .none ? .caution : nil
            )
            if let tempBasal = viewModel.activeTempBasalText {
                TandemInfoRow(
                    label: String(localized: "Temp basal"),
                    value: tempBasal,
                    tone: .info
                )
            }
            if viewModel.state.suspended {
                TandemInfoRow(
                    label: String(localized: "Delivery"),
                    value: String(localized: "Suspended"),
                    tone: .caution
                )
            }
        } header: {
            Text("Delivery").glassCaption()
        } footer: {
            Text(deliveryFooterText)
        }
        .tandemRowBackground()
    }

    /// Branches on the mode first, then the model — the other way round told a
    /// Mobi running microboluses that its pump was managing basal, and asked it
    /// to pick a mode it had already picked.
    private var deliveryFooterText: String {
        switch viewModel.basalControlMode {
        case .nativeTempRate:
            return String(
                localized: "Trio is controlling basal delivery with the pump's own temp rate command. Rates are sent as a percentage of the pump's active basal profile, so the profile must stay non-zero and Control-IQ must stay off."
            )
        case .microbolus:
            return String(
                localized: "Microbolus-basal looping is on: Trio delivers all basal as automatic microboluses, driven by the basal rates in Trio's therapy settings. The pump's own basal profile must stay at 0 U/hr with Control-IQ off."
            )
        case .none:
            let controlIQ = viewModel.state.controlIQEnabled ? String(localized: " (Control-IQ is on)") : ""
            return viewModel.supportsNativeBasal
                ? String(
                    localized: "Basal delivery is managed entirely by the pump\(controlIQ). Pick a basal control mode below to let Trio close the loop with this Mobi."
                )
                : String(
                    localized: "Basal delivery is managed entirely by the pump\(controlIQ). Trio records what the pump reports but cannot adjust basal on the t:slim X2, so closed loop is unavailable unless microbolus-basal is picked below."
                )
        }
    }

    // MARK: - Basal control

    /// One place to choose how basal is driven, so the two modes cannot be
    /// switched on independently — and, right underneath, whether the pump
    /// currently satisfies what that mode needs. Those conditions used to live
    /// in a footnote below the toggle, which is where a user looks last and
    /// where "Trio is not looping" was hardest to explain.
    private var basalModeSection: some View {
        Section {
            Picker(
                String(localized: "Basal is driven by"),
                selection: Binding(
                    get: { viewModel.basalControlMode },
                    set: { viewModel.requestBasalMode($0) }
                )
            ) {
                ForEach(viewModel.availableBasalModes, id: \.self) { mode in
                    Text(viewModel.basalModeTitle(mode)).tag(mode)
                }
            }
            .pickerStyle(.inline)

            Text(viewModel.basalModeSummary(viewModel.basalControlMode))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !viewModel.basalControlChecks.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(
                        viewModel.basalControlIsReady
                            ? String(localized: "Ready to loop")
                            : String(localized: "Trio cannot loop until these are true")
                    )
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(viewModel.basalControlIsReady ? Color.loopGreen : Color.warning)

                    ForEach(viewModel.basalControlChecks) { check in
                        TandemChecklistRow(text: check.text, isMet: check.isMet)
                    }

                    if viewModel.basalControlMode == .nativeTempRate,
                       let maxRate = viewModel.state.maximumTempRate
                    {
                        Text(
                            "At the pump's current profile rate, Trio can ask for 0 to \(TandemPumpState.rateText(maxRate)) U/hr — 0 to 250% of it."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
        } header: {
            Text("Basal control").glassCaption()
        } footer: {
            Text(basalModeFooter)
        }
        .tandemRowBackground()
    }

    /// Deliberately says something the mode summary above does not: the summary
    /// explains the mode that is selected, this explains the choice itself.
    private var basalModeFooter: String {
        viewModel.supportsNativeBasal
            ? String(
                localized: "Only one mode can be active, and switching stops whatever the other one was doing."
            )
            : String(
                localized: "The t:slim X2 has no remote temp-rate command, so microbolus-basal is the only way Trio can close the loop — and it is experimental and unverified on hardware."
            )
    }

    // MARK: - Remote bolus

    private var remoteBolusSection: some View {
        Section {
            Toggle(
                String(localized: "Allow remote bolus"),
                isOn: Binding(
                    get: { viewModel.remoteBolusEnabled },
                    set: { viewModel.requestRemoteBolusChange($0) }
                )
            )
            .disabled(!viewModel.state.supportsRemoteBolus && viewModel.state.apiVersionMajor > 0)
        } header: {
            Text("Remote bolus").glassCaption()
        } footer: {
            viewModel.state.supportsRemoteBolus || viewModel.state.apiVersionMajor == 0
                ? Text("Allows delivering manually confirmed boluses from Trio using the pump's mobile bolus feature.")
                : Text(
                    "This pump's software (API \(viewModel.apiVersionText)) does not support remote bolus; software 7.6 is required."
                )
        }
        .tandemRowBackground()
    }

    private var testDoseSection: some View {
        Section {
            Picker(String(localized: "Test amount"), selection: $viewModel.testDoseUnits) {
                ForEach(TandemSettingsViewModel.testDoseOptions, id: \.self) { amount in
                    Text("\(viewModel.formatTestDose(amount)) U").tag(amount)
                }
            }
            .disabled(viewModel.testDoseInProgress)

            TandemActionButton(
                title: String(localized: "Deliver \(viewModel.formatTestDose(viewModel.testDoseUnits)) U test bolus"),
                systemImage: "syringe",
                emphasis: .bordered,
                isBusy: viewModel.testDoseInProgress,
                busyTitle: String(localized: "Testing delivery…")
            ) {
                viewModel.requestTestDose()
            }

            if let result = viewModel.testDoseResult {
                TandemCallout(
                    title: result.success
                        ? String(localized: "The pump accepted it")
                        : String(localized: "The pump did not deliver it"),
                    message: result.message,
                    tone: result.success ? .ok : .critical
                )
            }
        } header: {
            Text("Diagnostics").glassCaption()
        } footer: {
            Text(viewModel.testDoseFooterText)
        }
        .tandemRowBackground()
    }

    // MARK: - Cartridge

    private var cartridgeSection: some View {
        Section {
            Toggle(
                String(localized: "Allow cartridge changes"),
                isOn: Binding(
                    get: { viewModel.cartridgeChangeEnabled },
                    set: { viewModel.requestCartridgeChangeEnabled($0) }
                )
            )
            if viewModel.cartridgeChangeInProgress {
                TandemCallout(
                    title: String(localized: "A change is open"),
                    message: String(
                        localized: "Insulin is stopped and Trio will not loop until the change is finished or cancelled."
                    ),
                    tone: .caution
                )
            }
            if viewModel.cartridgeChangeEnabled {
                TandemActionButton(
                    title: viewModel.cartridgeChangeInProgress
                        ? String(localized: "Resume cartridge change")
                        : String(localized: "Change cartridge"),
                    systemImage: "arrow.triangle.2.circlepath",
                    emphasis: viewModel.cartridgeChangeInProgress ? .prominent : .bordered
                ) {
                    viewModel.showCartridgeSheet = true
                }
            }
        } header: {
            Text("Cartridge").glassCaption()
        } footer: {
            Text(
                viewModel.isMobi
                    ? String(
                        localized: "Lets Trio walk through loading a new cartridge, filling the tubing and priming the cannula. Delivery is stopped and Trio will not loop for the whole change. Untested against a real Mobi; doing the change from the Tandem Mobi app is the safer option."
                    )
                    : String(
                        localized: "Lets Trio walk through loading a new cartridge and filling the tubing. Priming the cannula is a pump-screen operation on the t:slim X2. Delivery is stopped and Trio will not loop for the whole change."
                    )
            )
        }
        .tandemRowBackground()
    }

    // MARK: - Glucose alarms on the pump

    /// The pump's only annunciation command takes no arguments, so the two
    /// patterns are built here out of how many times Trio asks and how far
    /// apart — which is also why the test buttons matter more than usual.
    private var glucoseAlarmSection: some View {
        Section {
            Toggle(
                String(localized: "Buzz the pump on glucose alarms"),
                isOn: Binding(
                    get: { viewModel.glucoseAnnunciationEnabled },
                    set: { viewModel.setGlucoseAnnunciation($0) }
                )
            )

            if viewModel.glucoseAnnunciationEnabled {
                TandemInfoRow(
                    label: TandemGlucoseAlarmKind.low.localizedTitle,
                    value: viewModel.describePattern(.low),
                    tone: .critical
                )
                TandemInfoRow(
                    label: TandemGlucoseAlarmKind.high.localizedTitle,
                    value: viewModel.describePattern(.high),
                    tone: .caution
                )

                TandemActionButton(
                    title: String(localized: "Test the low pattern"),
                    systemImage: "arrow.down.circle",
                    emphasis: .bordered,
                    isBusy: viewModel.testingAnnunciation == .low,
                    busyTitle: String(localized: "Buzzing…")
                ) {
                    viewModel.testAnnunciation(.low)
                }
                .disabled(viewModel.testingAnnunciation != nil)

                TandemActionButton(
                    title: String(localized: "Test the high pattern"),
                    systemImage: "arrow.up.circle",
                    emphasis: .bordered,
                    isBusy: viewModel.testingAnnunciation == .high,
                    busyTitle: String(localized: "Buzzing…")
                ) {
                    viewModel.testAnnunciation(.high)
                }
                .disabled(viewModel.testingAnnunciation != nil)

                if viewModel.annunciationRefused, viewModel.annunciationResult == nil {
                    TandemCallout(
                        title: String(localized: "This pump refused the buzz"),
                        message: String(
                            localized: "Trio has stopped asking, so an alarm will not keep waking the pump to be refused again. The phone alert is unaffected. Press a test button to try once more — it may simply be a command your pump's software does not implement."
                        ),
                        tone: .caution
                    )
                }

                if let result = viewModel.annunciationResult {
                    TandemCallout(
                        title: result.success
                            ? String(localized: "The pump accepted it")
                            : String(localized: "The pump did not accept it"),
                        message: result.message,
                        // Not `.ok`: the pump accepting a command is not the
                        // same as the user having felt it.
                        tone: result.success ? .info : .critical
                    )
                }
            }
        } header: {
            Text("Glucose alarms").glassCaption()
        } footer: {
            Text(glucoseAlarmFooter)
        }
        .tandemRowBackground()
    }

    private var glucoseAlarmFooter: String {
        String(
            localized: "Uses Trio's own low and high alarms — the same thresholds, snooze and once-per-reading rule as the phone alert, so the pump never buzzes for something the phone stayed quiet about. Trio connects to the pump to deliver it rather than waiting for the next check-in, and never buzzes more than once every five minutes. Whether that comes out as a buzz, a beep or nothing at all is the pump's own Sound setting, not Trio's — set it to Vibrate in \(viewModel.elsewhereName). This command has not been verified against a real pump, and a pump that refuses it is not a fault you can fix here — use the test buttons before relying on it."
        )
    }

    // MARK: - Sounds

    private var soundsSection: some View {
        Section {
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
        } header: {
            Text("Sounds").glassCaption()
        } footer: {
            Text(
                "Tandem pumps cannot beep on command like an Omnipod, so Trio plays the confirmation sound on this phone instead: one tone when insulin delivery is accepted, another on cancel, suspend, or resume. Automatic doses (SMBs and basal microboluses) are silent unless enabled — with microbolus-basal looping on, they sound every loop cycle."
            )
        }
        .tandemRowBackground()
    }

    // MARK: - Pump identity

    private var aboutSection: some View {
        Section {
            TandemInfoRow(label: String(localized: "Model"), value: viewModel.model.localizedTitle)
            TandemInfoRow(
                label: String(localized: "Serial number"),
                value: viewModel.state.pumpSerial.isEmpty ? "—" : viewModel.state.pumpSerial
            )
            TandemInfoRow(
                label: String(localized: "Firmware"),
                value: viewModel.state.firmwareVersion.isEmpty ? "—" : viewModel.state.firmwareVersion
            )
            TandemInfoRow(label: String(localized: "API version"), value: viewModel.apiVersionText)
            // Every Mobi pairs with a 6-digit code, so saying so tells a Mobi
            // user nothing. On a t:slim X2 it depends on the pump's software and
            // is worth stating.
            if !viewModel.isMobi {
                TandemInfoRow(
                    label: String(localized: "Pairing"),
                    value: viewModel.state.pairingCodeType == .jpake6
                        ? String(localized: "6-digit code")
                        : String(localized: "16-character code")
                )
            }
            TandemInfoRow(
                label: String(localized: "Insulin"),
                value: viewModel.state.insulinType?.brandName ?? "—"
            )
            TandemInfoRow(label: String(localized: "Last sync"), value: viewModel.lastSyncText)
        } header: {
            Text("Pump").glassCaption()
        }
        .tandemRowBackground()
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
        .tandemRowBackground()
    }
}
