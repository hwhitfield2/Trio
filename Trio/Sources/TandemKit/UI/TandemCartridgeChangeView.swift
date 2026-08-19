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

    func begin() { run(pumpManager.beginCartridgeChange) }
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

    private var startSection: some View {
        Section(
            footer: Text(
                "The pump will not start a change while it is delivering insulin. Trio stops delivery first where it can; on a t:slim X2 you need to stop insulin on the pump yourself."
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
            fillTubingSection
        case .fillingTubing:
            stopFillingSection
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

    private var fillTubingSection: some View {
        Section(
            header: Text("Fill tubing"),
            footer: Text(
                "Filling pushes insulin through the tubing. Take the infusion set off your body first — insulin will come out of the end of the line."
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

    private var stopFillingSection: some View {
        Section(
            header: Text("Filling"),
            footer: Text("Stop as soon as insulin appears at the end of the tubing and no air is left in the line.")
        ) {
            Button(role: .destructive) {
                viewModel.stopFillTubing()
            } label: {
                buttonLabel(String(localized: "Stop filling tubing"))
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
            footer: Text("Finishing takes the pump out of cartridge-change mode so it can deliver again.")
        ) {
            Button {
                viewModel.finish()
            } label: {
                buttonLabel(String(localized: "Finish cartridge change"))
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
        case .changeMode: return String(localized: "Load the new cartridge")
        case .fillingTubing: return String(localized: "Filling the tubing")
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
