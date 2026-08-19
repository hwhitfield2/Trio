import LoopKit
import SwiftUI

/// Drives a cartridge change one step at a time.
///
/// The screen deliberately does not run the sequence for the user. Each step is
/// a separate button, because the physical work between steps — swapping the
/// cartridge, taking the set off the body, inserting a new one — is what makes
/// the next step safe, and only the user can tell Trio it happened.
final class TandemCartridgeChangeViewModel: ObservableObject, PumpManagerStatusObserver {
    @Published var busy = false
    @Published var errorMessage: String?
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

    var progressText: String? { state.lastCartridgeEventDescription }

    func formatUnits(_ units: Double) -> String {
        String(format: "%g", units)
    }

    func confirm(_ placement: TandemSetPlacement) {
        pumpManager.confirmSetPlacement(placement)
        placementConfirmed = placement
        objectWillChange.send()
    }

    private func run(_ action: (@escaping ((any LocalizedError)?) -> Void) -> Void) {
        busy = true
        errorMessage = nil
        action { [weak self] error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.busy = false
                self.errorMessage = error?.localizedDescription
                self.placementConfirmed = self.pumpManager.state.confirmedSetPlacement
                self.objectWillChange.send()
            }
        }
    }

    var alarmNames: String? { pumpManager.state.dismissableCartridgeAlarmNames }

    func begin() { run(pumpManager.beginCartridgeChange) }
    func acknowledgeAlarms() { run(pumpManager.acknowledgeCartridgeAlarms) }
    func cartridgeInserted() { run(pumpManager.confirmCartridgeInserted) }
    func refreshLoadStatus() { run(pumpManager.refreshLoadStatus) }
    func startFillTubing() { run(pumpManager.startFillTubing) }
    func stopFillTubing() { run(pumpManager.stopFillTubing) }
    func finish() { run(pumpManager.finishCartridgeChange) }
    func cancel() { run(pumpManager.cancelCartridgeChange) }

    func primeCannula() {
        let units = primeUnits
        run { completion in pumpManager.fillCannula(units: units, completion: completion) }
    }
}

struct TandemCartridgeChangeView: View {
    @ObservedObject var viewModel: TandemCartridgeChangeViewModel
    @State private var showCancelConfirmation = false

    var body: some View {
        Form {
            if !viewModel.state.cartridgeChangeEnabled {
                disabledSection
            } else {
                introSection
                if viewModel.isActive {
                    progressSection
                    stepsSection
                    cancelSection
                } else {
                    if viewModel.alarmNames != nil {
                        alarmSection
                    }
                    startSection
                }
            }
            if let error = viewModel.errorMessage {
                Section {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(Text("Change Cartridge"))
        .alert(String(localized: "Cancel the cartridge change?"), isPresented: $showCancelConfirmation) {
            Button(String(localized: "Keep going"), role: .cancel) {}
            Button(String(localized: "Cancel change"), role: .destructive) { viewModel.cancel() }
        } message: {
            Text(
                "Trio will try to take the pump out of cartridge-change mode. Check the pump afterwards: if it is still in a change, finish it on the pump itself before delivery can resume."
            )
        }
    }

    private var disabledSection: some View {
        Section {
            Text(
                "Cartridge changes from Trio are turned off. You can turn them on in the pump settings, or do the change on the pump itself as usual."
            )
            .font(.footnote)
        }
    }

    private var introSection: some View {
        Section(
            footer: Text(
                "Trio walks through the change one step at a time. Insulin delivery is stopped for the whole change, and Trio will not loop until you finish or cancel it."
            )
        ) {
            if let stage = viewModel.stage {
                row(String(localized: "Step"), stageTitle(stage))
            }
        }
    }

    /// Shown when the pump reports an alarm the change itself addresses. The
    /// pump refuses to start anything while alarming, so this is step zero.
    private var alarmSection: some View {
        Section(
            header: Text("Pump alarm"),
            footer: Text(
                "The pump will not start a cartridge change while it is alarming. Acknowledging clears the alarm — the same as tapping OK in the pump's own app — and then the change can start. Only this alarm is acknowledged; nothing else on the pump changes."
            )
        ) {
            if let names = viewModel.alarmNames {
                Button {
                    viewModel.acknowledgeAlarms()
                } label: {
                    buttonLabel(String(localized: "Acknowledge \(names) alarm"))
                }
                .disabled(viewModel.busy)
            }
        }
    }

    private var startSection: some View {
        Section(
            footer: Text(
                "The pump will not start a change while it is delivering insulin, so Trio stops delivery first and checks with the pump that it really stopped. On a t:slim X2 there is no remote stop — stop insulin on the pump yourself first."
            )
        ) {
            Button {
                viewModel.begin()
            } label: {
                buttonLabel(String(localized: "Start cartridge change"))
            }
            .disabled(viewModel.busy)

            Button {
                viewModel.refreshLoadStatus()
            } label: {
                Text("Check what the pump is doing")
            }
            .disabled(viewModel.busy)

            if let progress = viewModel.progressText {
                Text(progress).font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    private var progressSection: some View {
        Section(header: Text("Pump")) {
            if let progress = viewModel.progressText {
                Text(progress).font(.footnote).foregroundColor(.secondary)
            } else {
                Text("Waiting for the pump…").font(.footnote).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var stepsSection: some View {
        switch viewModel.stage {
        case .changeMode:
            swapCartridgeSection
        case .cartridgeLoaded:
            fillTubingSection
        case .fillingTubing:
            holdButtonSection
        case .tubingFilled:
            // The tubing fill can be repeated if air is still in the line, so
            // that step stays available alongside priming and finishing.
            if viewModel.supportsCannulaFill {
                primeCannulaSection
            }
            fillTubingSection
            finishSection
        case .cannulaFilled:
            finishSection
        case .none:
            EmptyView()
        }
    }

    private var swapCartridgeSection: some View {
        Section(
            header: Text("Swap the cartridge"),
            footer: Text(
                "Insulin is stopped. Remove the old cartridge and attach the new, filled one now. When it is on, continue — the pump will check the new cartridge (you'll see its progress here)."
            )
        ) {
            Button {
                viewModel.cartridgeInserted()
            } label: {
                buttonLabel(String(localized: "The new cartridge is installed"))
            }
            .disabled(viewModel.busy)
        }
    }

    private var fillTubingSection: some View {
        Section(
            header: Text("Fill tubing"),
            footer: Text(
                "Insulin will come out of the end of the line during the fill, so take the infusion set off your body first. Starting the fill only readies the pump — the insulin moves in the next step, while you hold the pump's button."
            )
        ) {
            Toggle(
                String(localized: "The set is disconnected from my body"),
                isOn: Binding(
                    get: { viewModel.placementConfirmed == .disconnected },
                    set: { isOn in if isOn { viewModel.confirm(.disconnected) } }
                )
            )
            Button {
                viewModel.startFillTubing()
            } label: {
                buttonLabel(String(localized: "Start filling tubing"))
            }
            .disabled(viewModel.busy || viewModel.placementConfirmed != .disconnected)
        }
    }

    private var holdButtonSection: some View {
        Section(
            header: Text("Hold the button on the pump"),
            footer: Text(
                "Trio cannot push the insulin — the pump requires a hand on the device for this step. Press and HOLD the button on the pump itself; insulin moves only while it is held. Release when insulin drips from the end of the tubing and no air is left in the line, then finish the step here. The pump will refuse to stop before any insulin has moved."
            )
        ) {
            Button {
                viewModel.stopFillTubing()
            } label: {
                buttonLabel(String(localized: "Done filling — insulin is at the tip"))
            }
            .disabled(viewModel.busy)
        }
    }

    private var primeCannulaSection: some View {
        Section(
            header: Text("Prime cannula"),
            footer: Text(
                "Priming fills the cannula itself, so the new set must already be inserted and connected. Use the fill volume your infusion set calls for. This insulin is not counted towards IOB, exactly as the pump does not count it."
            )
        ) {
            Toggle(
                String(localized: "The new set is inserted and connected"),
                isOn: Binding(
                    get: { viewModel.placementConfirmed == .inserted },
                    set: { isOn in if isOn { viewModel.confirm(.inserted) } }
                )
            )
            Picker(String(localized: "Fill volume"), selection: $viewModel.primeUnits) {
                ForEach(TandemCartridgeChangeViewModel.primeOptions, id: \.self) { units in
                    Text("\(viewModel.formatUnits(units)) U").tag(units)
                }
            }
            Button {
                viewModel.primeCannula()
            } label: {
                buttonLabel(String(localized: "Prime cannula"))
            }
            .disabled(viewModel.busy || viewModel.placementConfirmed != .inserted)
        }
    }

    private var finishSection: some View {
        Section(
            footer: Text(
                "Finishing restarts insulin delivery — make sure the infusion set is connected to your body first. The load itself is already complete."
            )
        ) {
            Button {
                viewModel.finish()
            } label: {
                buttonLabel(String(localized: "Finish and resume insulin"))
            }
            .disabled(viewModel.busy)
        }
    }

    private var cancelSection: some View {
        Section {
            Button(role: .destructive) {
                showCancelConfirmation = true
            } label: {
                buttonLabel(String(localized: "Cancel cartridge change"))
            }
            .disabled(viewModel.busy)
        }
    }

    private func stageTitle(_ stage: TandemCartridgeSession.Stage) -> String {
        switch stage {
        case .changeMode: return String(localized: "Swap the cartridge")
        case .cartridgeLoaded: return String(localized: "Cartridge loaded")
        case .fillingTubing: return String(localized: "Hold the pump's button to fill")
        case .tubingFilled: return String(localized: "Tubing filled")
        case .cannulaFilled: return String(localized: "Cannula primed")
        }
    }

    @ViewBuilder private func buttonLabel(_ title: String) -> some View {
        HStack {
            Spacer()
            if viewModel.busy {
                ProgressView()
            } else {
                Text(title)
            }
            Spacer()
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
