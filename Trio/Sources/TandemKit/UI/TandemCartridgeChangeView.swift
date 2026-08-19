import Combine
import LoopKit
import SwiftUI

/// Drives a cartridge change one step at a time.
///
/// The screen deliberately does not run the sequence for the user. Each step is
/// a separate button, because the physical work between steps — swapping the
/// cartridge, taking the set off the body, inserting a new one — is what makes
/// the next step safe, and only the user can tell Trio it happened.
final class TandemCartridgeChangeViewModel: ObservableObject, PumpManagerStatusObserver {
    /// Which command is running, so the screen can dim exactly one button
    /// instead of turning every button on it into an identical spinner.
    enum Action: Hashable {
        case begin
        case acknowledge
        case cartridgeInserted
        case refreshStatus
        case startFillTubing
        case stopFillTubing
        case primeCannula
        case finish
        case cancel
    }

    @Published var runningAction: Action?
    @Published var errorMessage: String?
    /// Which button the error belongs to, so it can be shown where it happened.
    @Published var failedAction: Action?
    @Published var placementConfirmed: TandemSetPlacement?
    @Published var primeUnits: Double = TandemCartridgeChangeViewModel.primeOptions[1]

    /// Typical Tandem cannula fill volumes; the pump accepts anything up to 3 U.
    static let primeOptions: [Double] = [0.2, 0.3, 0.5, 0.7, 1.0]

    let pumpManager: TandemPumpManager
    var didFinish: (() -> Void)?

    init(pumpManager: TandemPumpManager) {
        self.pumpManager = pumpManager
        placementConfirmed = pumpManager.state.confirmedSetPlacement
        // Progress arrives unsolicited from the pump, so redraw whenever the
        // driver publishes a state change rather than polling.
        pumpManager.addStatusObserver(self, queue: .main)
    }

    deinit {
        pumpManager.removeStatusObserver(self)
    }

    func pumpManager(_: PumpManager, didUpdate _: PumpManagerStatus, oldStatus _: PumpManagerStatus) {
        objectWillChange.send()
    }

    var state: TandemPumpState { pumpManager.state }
    var stage: TandemCartridgeSession.Stage? { state.cartridgeSession?.stage }
    var isActive: Bool { state.cartridgeSession != nil }
    var supportsCannulaFill: Bool { state.pumpModel.supportsRemoteCannulaFill }
    var isMobi: Bool { state.pumpModel == .mobi }

    var busy: Bool { runningAction != nil }

    func isRunning(_ action: Action) -> Bool { runningAction == action }

    func error(for action: Action) -> String? {
        failedAction == action ? errorMessage : nil
    }

    var progressText: String? { state.lastCartridgeEventDescription }

    /// 0…1 while the pump is detecting a newly installed cartridge. The pump
    /// streams a real percentage here and it used to be flattened into a
    /// sentence; a bar is what a 20-second wait needs.
    var detectionFraction: Double? {
        guard let percent = state.cartridgeDetectionPercent else { return nil }
        return min(max(Double(percent) / 100, 0), 1)
    }

    var detectionPercentText: String? {
        guard let percent = state.cartridgeDetectionPercent else { return nil }
        return String(localized: "\(percent)%")
    }

    /// Whether the pump reports its own fill button held down right now. On a
    /// Mobi this is the only feedback that insulin is actually moving, and the
    /// user's eyes are on the pump, not the phone.
    var fillButtonDown: Bool? { state.fillTubingButtonDown }

    // MARK: - Steps

    /// The steps the USER performs, so the screen can say "step 3 of 4" rather
    /// than leaving them to guess how much is left with insulin stopped.
    ///
    /// Detecting the cartridge is not in the list: the pump does that on its
    /// own between two of these, and it has its own progress bar. Every entry
    /// here is something the user is asked to do, and the t:slim X2 has one
    /// fewer because it cannot prime a cannula remotely.
    var stepTitles: [String] {
        var titles = [
            String(localized: "Swap the cartridge"),
            String(localized: "Fill the tubing")
        ]
        if supportsCannulaFill {
            titles.append(String(localized: "Prime the cannula"))
        }
        // Resuming is a Mobi command. On a t:slim X2 Trio can close the change
        // but cannot restart delivery, so the step is named for what the user
        // actually has to do.
        titles.append(
            isMobi
                ? String(localized: "Resume insulin")
                : String(localized: "Restart insulin on the pump")
        )
        return titles
    }

    /// The step whose action is on screen right now.
    var currentStepIndex: Int {
        switch stage {
        case .changeMode:
            return 0
        case .cartridgeLoaded,
             .fillingTubing:
            return 1
        case .tubingFilled:
            // Index 2 is "Prime the cannula" on a Mobi and "Resume insulin" on
            // a t:slim X2, which is exactly the action each one is offered.
            return 2
        case .cannulaFilled:
            return stepTitles.count - 1
        case .none:
            return 0
        }
    }

    /// How long this change has been open. The driver stops trusting a session
    /// after two hours; the screen says so before it happens rather than
    /// failing a command afterwards.
    var sessionAgeWarning: String? {
        guard let session = state.cartridgeSession else { return nil }
        let remaining = TandemCartridgeSession.maximumDuration - Date.now.timeIntervalSince(session.startedAt)
        guard remaining < .minutes(30) else { return nil }
        if remaining <= 0 {
            return String(
                localized: "This change has been open for over two hours, so Trio no longer trusts what the pump is doing. Cancel it and check the pump."
            )
        }
        return String(
            localized: "This change has been open a while. Trio stops trusting it after two hours — about \(Int(remaining / 60)) minutes from now."
        )
    }

    // MARK: - Placement confirmation

    /// Seconds left on the current placement confirmation, or nil when there is
    /// none. A confirmation goes stale after ten minutes and the driver refuses
    /// the step; before this the screen kept showing a ticked box.
    var placementSecondsRemaining: Int? {
        guard state.confirmedSetPlacement != nil,
              let confirmedAt = state.cartridgeDisconnectConfirmedAt
        else { return nil }
        let remaining = TandemPumpState.disconnectConfirmationValidity - Date.now.timeIntervalSince(confirmedAt)
        return remaining > 0 ? Int(remaining) : 0
    }

    func hasFreshConfirmation(_ placement: TandemSetPlacement) -> Bool {
        state.confirmedSetPlacement == placement && state.hasFreshDisconnectConfirmation()
    }

    func confirmationExpiryText(for placement: TandemSetPlacement) -> String? {
        guard state.confirmedSetPlacement == placement, let seconds = placementSecondsRemaining else { return nil }
        if seconds <= 0 {
            return String(localized: "This confirmation has expired — answer again before continuing.")
        }
        return String(localized: "Confirmed. Valid for another \(max(1, seconds / 60)) min.")
    }

    func confirm(_ placement: TandemSetPlacement) {
        pumpManager.confirmSetPlacement(placement)
        placementConfirmed = placement
        TandemHaptics.selection()
        objectWillChange.send()
    }

    /// Withdraw a confirmation. A safety answer that can only be replaced by
    /// its opposite is not really a question.
    func withdrawConfirmation() {
        pumpManager.clearSetPlacement()
        placementConfirmed = nil
        TandemHaptics.selection()
        objectWillChange.send()
    }

    /// The fill runs from the pump for both models, but a Mobi has one physical
    /// button and a t:slim X2 has a screen, so the instruction cannot be shared.
    var holdButtonFooter: String {
        let shared = String(
            localized: "Trio cannot push the insulin — the pump requires a hand on the device for this step."
        )
        let closing = String(
            localized: "Stop when insulin drips from the end of the tubing and no air is left in the line, then finish the step here. The pump will refuse to stop before any insulin has moved."
        )
        return isMobi
            ? String(
                localized: "\(shared) Press and HOLD the button on the pump itself; insulin moves only while it is held. \(closing)"
            )
            : String(
                localized: "\(shared) Start the fill on the pump's own screen; insulin moves only while the pump is filling. \(closing)"
            )
    }

    // MARK: - Copy that depends on the pump

    /// A Mobi has no screen, so "do it on the pump itself" is not advice that
    /// can be followed there — the Tandem Mobi app is.
    var elsewhereName: String {
        isMobi ? String(localized: "the Tandem Mobi app") : String(localized: "the pump itself")
    }

    var alarmNames: String? { state.dismissableCartridgeAlarmNames }

    // MARK: - Commands

    private func run(_ action: Action, _ body: (@escaping ((any LocalizedError)?) -> Void) -> Void) {
        runningAction = action
        errorMessage = nil
        failedAction = nil
        body { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.runningAction = nil
                self.errorMessage = error?.localizedDescription
                self.failedAction = error == nil ? nil : action
                self.placementConfirmed = self.pumpManager.state.confirmedSetPlacement
                if error == nil {
                    TandemHaptics.success()
                } else {
                    TandemHaptics.failure()
                }
                self.objectWillChange.send()
            }
        }
    }

    func begin() { run(.begin, pumpManager.beginCartridgeChange) }
    // The cartridge screen clears the leftover load alerts alongside the
    // alarms, because the user finishing the change here is the completion of
    // the operations those alerts record.
    func acknowledgeAlarms() {
        run(.acknowledge) { completion in
            pumpManager.acknowledgeCartridgeAlarms(includingLoadAlerts: true, completion: completion)
        }
    }
    func cartridgeInserted() { run(.cartridgeInserted, pumpManager.confirmCartridgeInserted) }
    func refreshLoadStatus() { run(.refreshStatus, pumpManager.refreshLoadStatus) }
    func startFillTubing() { run(.startFillTubing, pumpManager.startFillTubing) }
    func stopFillTubing() { run(.stopFillTubing, pumpManager.stopFillTubing) }
    func finish() { run(.finish, pumpManager.finishCartridgeChange) }
    func cancel() { run(.cancel, pumpManager.cancelCartridgeChange) }

    func primeCannula() {
        let units = primeUnits
        run(.primeCannula) { completion in pumpManager.fillCannula(units: units, completion: completion) }
    }

    func formatUnits(_ units: Double) -> String {
        TandemPumpState.doseText(units)
    }
}

struct TandemCartridgeChangeView: View {
    @ObservedObject var viewModel: TandemCartridgeChangeViewModel
    @State private var showCancelConfirmation = false
    /// Kept shut by default: see the `.tubingFilled` case below.
    @State private var showRefillTubing = false

    /// A placement confirmation expires after ten minutes and the two-hour
    /// session limit runs down the whole time, but nothing in the driver
    /// changes when a clock passes a threshold — so without this the screen
    /// would keep showing a ticked box and an enabled button over a
    /// confirmation the driver would refuse.
    @State private var ticker = Timer.publish(every: 15, on: .main, in: .common).autoconnect()
    @State private var now = Date.now

    var body: some View {
        List {
            if !viewModel.state.cartridgeChangeEnabled {
                disabledSection
            } else if viewModel.isActive {
                progressSection
                if let warning = viewModel.sessionAgeWarning {
                    staleSection(warning)
                }
                stepsSection
                cancelSection
            } else {
                strandedErrorSection
                if viewModel.alarmNames != nil {
                    alarmSection
                }
                introSection
                startSection
            }
        }
        .tandemScreenBackground()
        .onReceive(ticker) { now = $0 }
        // Leaving the stage closes the detour, so coming back to "tubing
        // filled" starts from the real next step again.
        .onChange(of: viewModel.stage) { _, _ in showRefillTubing = false }
        .navigationTitle(Text("Change Cartridge"))
        .navigationBarTitleDisplayMode(.inline)
        .alert(String(localized: "Cancel the cartridge change?"), isPresented: $showCancelConfirmation) {
            Button(String(localized: "Keep going"), role: .cancel) {}
            Button(String(localized: "Cancel change"), role: .destructive) { viewModel.cancel() }
        } message: {
            Text(
                "Trio will try to take the pump out of cartridge-change mode. Check the pump afterwards: if it is still in a change, finish it in \(viewModel.elsewhereName) before delivery can resume."
            )
        }
    }

    /// `finishCartridgeChange` and `cancelCartridgeChange` close the session
    /// even when they fail, so the section that would have shown their error is
    /// gone by the time it arrives — and both of those failures leave insulin
    /// stopped. The message has to outlive the section.
    @ViewBuilder private var strandedErrorSection: some View {
        if let action = viewModel.failedAction,
           action == .finish || action == .cancel,
           let message = viewModel.errorMessage
        {
            Section {
                TandemCallout(
                    title: action == .finish
                        ? String(localized: "Insulin did not restart")
                        : String(localized: "The change was not cleanly cancelled"),
                    message: message,
                    tone: .critical
                )
            }
            .tandemRowBackground()
        }
    }

    // MARK: - Not enabled

    private var disabledSection: some View {
        Section {
            TandemCallout(
                title: String(localized: "Cartridge changes are turned off"),
                message: String(
                    localized: "Turn them on under Cartridge on this pump's screen in Trio, or do the change the usual way. Trio does not need to be involved in a cartridge change."
                ),
                tone: .info
            )
        }
        .tandemRowBackground()
    }

    // MARK: - Before starting

    private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.stepTitles.enumerated()), id: \.offset) { index, title in
                    HStack(spacing: 10) {
                        Text(verbatim: "\(index + 1)")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.insulin)
                            .frame(width: 20, height: 20)
                            .background(Color.insulin.opacity(0.15), in: Circle())
                        Text(title)
                            .font(.footnote)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.vertical, 2)
        } header: {
            Text("What happens").glassCaption()
        } footer: {
            Text(
                "Insulin delivery is stopped for the whole change and Trio will not loop until you finish or cancel it. Each step waits for you — nothing runs on its own."
            )
        }
        .tandemRowBackground()
    }

    /// Shown when the pump reports an alarm or leftover load alert the change
    /// itself addresses. The pump refuses to start anything while alarming,
    /// and refuses to resume over an incomplete-load alert, so this is step
    /// zero.
    private var alarmSection: some View {
        Section {
            TandemCallout(
                title: viewModel.alarmNames ?? String(localized: "Pump alarm"),
                message: String(
                    localized: "The pump blocks operations while these stand — an alarm stops a change from starting, and a leftover \"incomplete\" alert from an interrupted load stops insulin from resuming. Acknowledging clears them, the same as answering them in \(viewModel.elsewhereName). Nothing else on the pump changes; warnings like Low Insulin are never cleared by Trio."
                ),
                tone: .critical,
                symbolName: "bell.badge.fill"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if let names = viewModel.alarmNames {
                        TandemActionButton(
                            title: String(localized: "Acknowledge \(names)"),
                            systemImage: "checkmark.circle",
                            isBusy: viewModel.isRunning(.acknowledge),
                            busyTitle: String(localized: "Acknowledging…")
                        ) {
                            viewModel.acknowledgeAlarms()
                        }
                        .disabled(viewModel.busy)
                    }
                    errorText(for: .acknowledge)
                }
            }
        } header: {
            Text("First, clear the alarm").glassCaption()
        }
        .tandemRowBackground()
    }

    private var startSection: some View {
        Section {
            TandemActionButton(
                title: String(localized: "Start cartridge change"),
                systemImage: "play.circle",
                isBusy: viewModel.isRunning(.begin),
                busyTitle: String(localized: "Stopping insulin…")
            ) {
                viewModel.begin()
            }
            .disabled(viewModel.busy)

            errorText(for: .begin)

            TandemActionButton(
                title: String(localized: "Check what the pump is doing"),
                systemImage: "stethoscope",
                emphasis: .bordered,
                isBusy: viewModel.isRunning(.refreshStatus),
                busyTitle: String(localized: "Asking the pump…")
            ) {
                viewModel.refreshLoadStatus()
            }
            .disabled(viewModel.busy)

            errorText(for: .refreshStatus)

            if let progress = viewModel.progressText {
                Text(progress)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } footer: {
            Text(startFooter)
        }
        .tandemRowBackground()
    }

    private var startFooter: String {
        viewModel.isMobi
            ? String(
                localized: "The pump will not start a change while it is delivering insulin, so Trio stops delivery first and checks with the pump that it really stopped."
            )
            : String(
                localized: "The pump will not start a change while it is delivering insulin. A t:slim X2 has no remote stop, so stop insulin on the pump yourself first."
            )
    }

    // MARK: - Progress

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                TandemStepRail(titles: viewModel.stepTitles, currentIndex: viewModel.currentStepIndex)

                if let fraction = viewModel.detectionFraction, viewModel.stage == .cartridgeLoaded {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Checking the new cartridge")
                                .font(.footnote)
                            Spacer()
                            Text(viewModel.detectionPercentText ?? "")
                                .font(.footnote)
                                .fontDesign(.rounded)
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: fraction)
                            .tint(Color.insulin)
                    }
                    .accessibilityElement(children: .combine)
                }

                if let progress = viewModel.progressText {
                    Text(progress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Waiting for the pump…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        } header: {
            Text("Progress").glassCaption()
        }
        .tandemRowBackground()
    }

    private func staleSection(_ warning: String) -> some View {
        Section {
            TandemCallout(
                title: String(localized: "Time is running out on this change"),
                message: warning,
                tone: .caution
            )
        }
        .tandemRowBackground()
    }

    // MARK: - Steps

    @ViewBuilder private var stepsSection: some View {
        switch viewModel.stage {
        case .changeMode:
            swapCartridgeSection
        case .cartridgeLoaded:
            fillTubingSection
        case .fillingTubing:
            holdButtonSection
        case .tubingFilled:
            // Only one thing should look like the next step. On a Mobi that is
            // the cannula prime; on a t:slim X2 it is finishing. Refilling the
            // tubing stays available for air still in the line, but stays shut
            // until asked for — its confirmation is the exact opposite of the
            // prime's ("off my body" against "inserted and connected"), and the
            // two must never be answerable side by side.
            if showRefillTubing {
                // While this is open it is the only thing on screen, so the
                // "off my body" answer it needs cannot be given next to the
                // prime's "inserted and connected".
                refillTubingSection
            } else if viewModel.supportsCannulaFill {
                primeCannulaSection
                finishSection(emphasis: .bordered)
                refillTubingPrompt
            } else {
                finishSection(emphasis: .prominent)
                refillTubingPrompt
            }
        case .cannulaFilled:
            finishSection(emphasis: .prominent)
        case .none:
            EmptyView()
        }
    }

    private var swapCartridgeSection: some View {
        Section {
            TandemActionButton(
                title: String(localized: "The new cartridge is installed"),
                systemImage: "checkmark.circle",
                isBusy: viewModel.isRunning(.cartridgeInserted),
                busyTitle: String(localized: "Telling the pump…")
            ) {
                viewModel.cartridgeInserted()
            }
            .disabled(viewModel.busy)

            errorText(for: .cartridgeInserted)
        } header: {
            Text("Swap the cartridge").glassCaption()
        } footer: {
            Text(
                "Insulin is stopped. Remove the old cartridge and attach the new, filled one now. When it is on, continue — the pump will check the new cartridge and you will see its progress here."
            )
        }
        .tandemRowBackground()
    }

    /// The set must be OFF the body: this step sprays insulin out of the end of
    /// the line. It is deliberately styled as a warning, and its opposite (the
    /// cannula prime, which needs the set ON the body) never appears beside it.
    private var fillTubingSection: some View {
        Section {
            placementConfirmation(
                .disconnected,
                title: String(localized: "The set is disconnected from my body"),
                consequence: String(localized: "Insulin will come out of the end of the line."),
                tone: .caution,
                symbol: "arrow.up.and.down.and.arrow.left.and.right"
            )

            TandemActionButton(
                title: String(localized: "Start filling tubing"),
                systemImage: "drop.triangle",
                isBusy: viewModel.isRunning(.startFillTubing),
                busyTitle: String(localized: "Opening the fill…")
            ) {
                viewModel.startFillTubing()
            }
            .disabled(viewModel.busy || !viewModel.hasFreshConfirmation(.disconnected))

            errorText(for: .startFillTubing)
        } header: {
            Text("Fill the tubing").glassCaption()
        } footer: {
            Text(
                "Take the infusion set off your body first. Starting the fill only readies the pump — the insulin moves in the next step, while you hold the pump's button."
            )
        }
        .tandemRowBackground()
    }

    /// The way back to a tubing fill, kept behind a press so its confirmation is
    /// never on screen next to the prime's opposite one.
    private var refillTubingPrompt: some View {
        Section {
            Button {
                // Answering "the set is off my body" is what this opens, so the
                // previous answer must not carry over into it.
                viewModel.withdrawConfirmation()
                showRefillTubing = true
            } label: {
                Text("Still air in the line? Fill the tubing again")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(viewModel.busy)
        }
        .tandemRowBackground()
    }

    /// Same command, but reached from `tubingFilled` when air is still in the
    /// line. Kept quiet so it never competes with the real next step.
    private var refillTubingSection: some View {
        Section {
            placementConfirmation(
                .disconnected,
                title: String(localized: "The set is disconnected from my body"),
                consequence: String(localized: "Insulin will come out of the end of the line."),
                tone: .caution,
                symbol: "arrow.up.and.down.and.arrow.left.and.right"
            )

            TandemActionButton(
                title: String(localized: "Fill the tubing again"),
                systemImage: "arrow.clockwise",
                emphasis: .bordered,
                isBusy: viewModel.isRunning(.startFillTubing),
                busyTitle: String(localized: "Opening the fill…")
            ) {
                viewModel.startFillTubing()
            }
            .disabled(viewModel.busy || !viewModel.hasFreshConfirmation(.disconnected))

            errorText(for: .startFillTubing)

            Button {
                viewModel.withdrawConfirmation()
                showRefillTubing = false
            } label: {
                Text("Never mind — go back")
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .disabled(viewModel.busy)
        } header: {
            Text("Still air in the line?").glassCaption()
        } footer: {
            Text("Only if you can still see air. The set has to come off your body again for this.")
        }
        .tandemRowBackground()
    }

    /// The one step Trio cannot drive. The pump fills only while its own button
    /// is held, and the pump reports that button going down — so the phone
    /// mirrors the hardware instead of showing a static paragraph.
    private var holdButtonSection: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: viewModel.fillButtonDown == true ? "hand.point.up.left.fill" : "hand.point.up.left")
                    .font(.title2)
                    .foregroundStyle(viewModel.fillButtonDown == true ? Color.insulin : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(buttonStateTitle)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(viewModel.fillButtonDown == true ? Color.insulin : Color.primary)
                    Text(buttonStateDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(buttonStateTitle). \(buttonStateDetail)")

            TandemActionButton(
                title: String(localized: "Done filling — insulin is at the tip"),
                systemImage: "checkmark.circle",
                isBusy: viewModel.isRunning(.stopFillTubing),
                busyTitle: String(localized: "Closing the fill…")
            ) {
                viewModel.stopFillTubing()
            }
            .disabled(viewModel.busy)

            errorText(for: .stopFillTubing)
        } header: {
            Text(viewModel.isMobi ? "Hold the button on the pump" : "Fill from the pump").glassCaption()
        } footer: {
            Text(viewModel.holdButtonFooter)
        }
        .tandemRowBackground()
    }

    private var buttonStateTitle: String {
        guard let down = viewModel.fillButtonDown else {
            return String(localized: "Waiting for the pump's button")
        }
        return down
            ? String(localized: "Filling — button held")
            : String(localized: "Button released")
    }

    private var buttonStateDetail: String {
        guard let down = viewModel.fillButtonDown else {
            return viewModel.isMobi
                ? String(localized: "Press and hold the button on the pump to move insulin.")
                : String(localized: "Start the fill on the pump to move insulin.")
        }
        if down {
            return String(localized: "Insulin is moving through the line right now.")
        }
        return viewModel.isMobi
            ? String(localized: "Hold the button again if there is still air in the line.")
            : String(localized: "Fill again on the pump if there is still air in the line.")
    }

    /// The opposite confirmation: the set must be ON the body, because the prime
    /// fills the cannula's dead space at the site.
    private var primeCannulaSection: some View {
        Section {
            placementConfirmation(
                .inserted,
                title: String(localized: "The new set is inserted and connected"),
                consequence: String(localized: "The prime pushes insulin into the site."),
                tone: .info,
                symbol: "bandage"
            )

            Picker(String(localized: "Fill volume"), selection: $viewModel.primeUnits) {
                ForEach(TandemCartridgeChangeViewModel.primeOptions, id: \.self) { units in
                    Text("\(viewModel.formatUnits(units)) U").tag(units)
                }
            }
            .disabled(viewModel.busy)

            TandemActionButton(
                title: String(localized: "Prime cannula"),
                systemImage: "drop.fill",
                isBusy: viewModel.isRunning(.primeCannula),
                busyTitle: String(localized: "Priming…")
            ) {
                viewModel.primeCannula()
            }
            .disabled(viewModel.busy || !viewModel.hasFreshConfirmation(.inserted))

            errorText(for: .primeCannula)
        } header: {
            Text("Prime the cannula").glassCaption()
        } footer: {
            Text(
                "Priming fills the cannula itself, so the new set must already be inserted and connected. Use the fill volume your infusion set calls for. This insulin is not counted towards IOB, exactly as the pump does not count it."
            )
        }
        .tandemRowBackground()
    }

    private func finishSection(emphasis: TandemActionButton.Emphasis) -> some View {
        Section {
            TandemActionButton(
                title: viewModel.isMobi
                    ? String(localized: "Finish and resume insulin")
                    : String(localized: "Finish the change"),
                systemImage: "play.fill",
                emphasis: emphasis,
                isBusy: viewModel.isRunning(.finish),
                busyTitle: String(localized: "Restarting insulin…")
            ) {
                viewModel.finish()
            }
            .disabled(viewModel.busy)

            errorText(for: .finish)
        } header: {
            Text(viewModel.isMobi ? "Resume insulin" : "Finish").glassCaption()
        } footer: {
            Text(
                viewModel.isMobi
                    ? String(
                        localized: "Finishing restarts insulin delivery — make sure the infusion set is connected to your body first. The load itself is already complete."
                    )
                    : String(
                        localized: "The load itself is already complete. A t:slim X2 has no remote resume, so restart insulin on the pump once the infusion set is connected to your body."
                    )
            )
        }
        .tandemRowBackground()
    }

    private var cancelSection: some View {
        Section {
            TandemActionButton(
                title: String(localized: "Cancel cartridge change"),
                systemImage: "xmark.circle",
                emphasis: .destructive,
                isBusy: viewModel.isRunning(.cancel),
                busyTitle: String(localized: "Cancelling…")
            ) {
                showCancelConfirmation = true
            }
            .disabled(viewModel.busy)

            errorText(for: .cancel)
        }
        .tandemRowBackground()
    }

    // MARK: - Shared pieces

    /// A placement answer, styled by what it authorises rather than as a plain
    /// toggle: the two the flow needs are opposites, and only one of them is
    /// ever on screen.
    @ViewBuilder private func placementConfirmation(
        _ placement: TandemSetPlacement,
        title: String,
        consequence: String,
        tone: TandemTone,
        symbol: String
    ) -> some View {
        let fresh = viewModel.hasFreshConfirmation(placement)

        VStack(alignment: .leading, spacing: 8) {
            Button {
                // Tapping a live confirmation takes it back; tapping an expired
                // one answers again. Making an expired tick behave like a live
                // one would cost two taps and the first would look like nothing
                // happened.
                if fresh {
                    viewModel.withdrawConfirmation()
                } else {
                    viewModel.confirm(placement)
                }
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: fresh ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(fresh ? tone.color : Color.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .foregroundStyle(Color.primary)
                            .multilineTextAlignment(.leading)
                        HStack(spacing: 4) {
                            Image(systemName: symbol)
                                .imageScale(.small)
                            Text(consequence)
                        }
                        .font(.caption)
                        .foregroundStyle(tone.color)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(viewModel.busy)
            .accessibilityAddTraits(fresh ? [.isSelected] : [])
            .accessibilityHint(
                fresh
                    ? String(localized: "Tap to take this confirmation back")
                    : String(localized: "Tap to confirm")
            )

            if let expiry = viewModel.confirmationExpiryText(for: placement) {
                Text(expiry)
                    .font(.caption2)
                    .foregroundStyle(fresh ? Color.secondary : Color.warning)
            }
        }
        .padding(.vertical, 2)
    }

    /// The failure belongs next to the button that caused it, not at the bottom
    /// of the screen where the old red footnote lived.
    @ViewBuilder private func errorText(for action: TandemCartridgeChangeViewModel.Action) -> some View {
        if let message = viewModel.error(for: action) {
            TandemCallout(
                title: String(localized: "The pump did not do that"),
                message: message,
                tone: .critical
            )
        }
    }
}
