import Combine
import CoreBluetooth
import LoopKit
import SwiftUI

final class TandemPairingViewModel: ObservableObject {
    enum Step {
        case intro
        case scanning
        case codeEntry
        case pairing
        case done
    }

    @Published var step: Step = .intro
    @Published var discoveredPumps: [TandemScanResult] = []
    @Published var selectedPump: TandemScanResult?
    @Published var pairingCode: String = ""
    @Published var insulinType: InsulinType = .novolog
    @Published var errorMessage: String?

    let allowedInsulinTypes: [InsulinType]
    private let pumpManager: TandemPumpManager
    private let workQueue = DispatchQueue(label: "org.nightscout.trio.TandemPairingViewModel", qos: .userInitiated)

    var didFinish: (() -> Void)?
    var didCancel: (() -> Void)?

    init(pumpManager: TandemPumpManager, allowedInsulinTypes: [InsulinType]) {
        self.pumpManager = pumpManager
        let types = allowedInsulinTypes.isEmpty ? [.novolog, .humalog, .apidra, .fiasp, .lyumjev] : allowedInsulinTypes
        self.allowedInsulinTypes = types
        // Start on a type the picker actually offers. A default outside the
        // allowed list leaves the picker showing nothing selected, and pairing
        // then records an insulin type the user never chose.
        if !types.contains(insulinType), let first = types.first {
            insulinType = first
        }
    }

    /// Model of the pump the user picked, as far as its advertised name says.
    var selectedModel: TandemPumpModel? {
        selectedPump?.model
    }

    /// A Mobi always uses a 6-digit code (it has no screen of its own; the code
    /// comes from the Tandem Mobi app during pairing), so its entry field can be
    /// numeric-only and its instructions specific.
    var expectsSixDigitCode: Bool {
        selectedModel == .mobi
    }

    var codeFieldPrompt: String {
        expectsSixDigitCode
            ? String(localized: "6-digit code")
            : String(localized: "Pairing code from the pump")
    }

    /// What to tell the user about the code, once the pump is known. Before a
    /// pump is picked both models are in play; afterwards only one is.
    var codeInstruction: String {
        switch selectedModel {
        case .mobi:
            return String(
                localized: "A Tandem Mobi pairs with a 6-digit code. Start pairing in the Tandem Mobi app so the pump is ready to accept a new device, then enter the code here."
            )
        case .tslimX2:
            return String(
                localized: "A t:slim X2 shows its pairing code on the pump screen: 16 characters on software 7.1–7.6, or 6 digits on 7.7 and newer. Start pairing on the pump, then enter the code exactly as shown."
            )
        case .none:
            return String(
                localized: "Enter the pairing code: 6 digits from the Tandem Mobi app on a Mobi, 6 digits on t:slim X2 software 7.7 and newer, or 16 characters shown on a t:slim X2 running 7.1–7.6."
            )
        }
    }

    /// Longest code either handshake uses, so the field can stop the user
    /// overtyping rather than failing after the fact.
    var codeCharacterLimit: Int {
        expectsSixDigitCode ? 6 : 16
    }

    /// True once what has been typed could be a valid code. Enabling the button
    /// only then keeps the user from tying up the pump's pairing screen with a
    /// half-entered code.
    var codeLooksComplete: Bool {
        let normalized = TandemPumpSession.normalizePairingCode(pairingCode)
        guard let type = TandemPairingCodeType.from(pairingCode: normalized) else { return false }
        if selectedModel == .mobi, type != .jpake6 { return false }
        return true
    }

    var isBluetoothPoweredOn: Bool { pumpManager.bluetooth.isBluetoothPoweredOn }

    func startScan() {
        step = .scanning
        errorMessage = nil
        discoveredPumps = []
        pumpManager.bluetooth.startScan { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.discoveredPumps.contains(where: { $0.id == result.id }) {
                    self.discoveredPumps.append(result)
                    TandemHaptics.selection()
                }
            }
        }
    }

    func select(pump: TandemScanResult) {
        selectedPump = pump
        pumpManager.bluetooth.stopScan()
        errorMessage = nil
        step = .codeEntry
    }

    /// Go back to the pump list — the recovery a failed pairing usually needs
    /// when the wrong pump was picked out of two in the room.
    func chooseAnotherPump() {
        selectedPump = nil
        pairingCode = ""
        startScan()
    }

    func pair() {
        guard let pump = selectedPump else { return }
        let normalized = TandemPumpSession.normalizePairingCode(pairingCode)

        guard let codeType = TandemPairingCodeType.from(pairingCode: normalized) else {
            errorMessage = String(
                localized: "Enter either the 6-digit code (Tandem Mobi, or t:slim X2 software 7.7 and newer) or the 16-character code (t:slim X2 software 7.1 to 7.6)."
            )
            return
        }
        // A Mobi has no legacy handshake at all, so a 16-character code here is
        // a mistake worth catching before we tie up the pump's pairing screen.
        if pump.model == .mobi, codeType != .jpake6 {
            errorMessage = String(localized: "The Tandem Mobi pairs with a 6-digit code.")
            return
        }

        errorMessage = nil
        step = .pairing

        workQueue.async { [weak self] in
            guard let self = self else { return }

            var connectError: TandemConnectionError?
            let semaphore = DispatchSemaphore(value: 0)
            self.pumpManager.bluetooth.connect(identifier: pump.id) { error in
                connectError = error
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + 40) == .success, connectError == nil else {
                self.fail(connectError?.localizedDescription ?? String(localized: "Connection timed out."))
                return
            }

            // Prefer the model the pump advertised; if it did not advertise a
            // recognizable name, start from the conservative default. The
            // identity refresh that follows pairing corrects it from the pump's
            // API version.
            let model = pump.model ?? .default
            var derivedSecret: Data?

            switch codeType {
            case .legacy16:
                if case let .failure(error) = self.pumpManager.session.authenticate(pairingCode: normalized) {
                    self.fail(error.localizedDescription)
                    return
                }
            case .jpake6:
                // No stored secret: this runs the full elliptic-curve handshake,
                // which takes a few seconds.
                let result = self.pumpManager.session.authenticateJpake(
                    pairingCode: normalized,
                    derivedSecret: nil
                )
                switch result {
                case let .success(keys):
                    derivedSecret = keys.derivedSecret
                case let .failure(error):
                    self.fail(error.localizedDescription)
                    return
                }
            }

            self.pumpManager.completePairing(
                peripheralIdentifier: pump.id,
                pairingCode: normalized,
                pairingCodeType: codeType,
                pumpModel: model,
                jpakeDerivedSecret: derivedSecret,
                insulinType: self.insulinType
            )
            DispatchQueue.main.async {
                TandemHaptics.success()
                self.step = .done
            }
        }
    }

    /// What Trio will and will not be able to do with the pump that was just
    /// paired. The two models give it genuinely different roles, and this is the
    /// moment to say which one the user has.
    var pairedCapabilitySummary: String {
        let model = pumpManager.state.pumpModel
        switch model {
        case .mobi:
            return String(
                localized: "Trio can now read this Mobi's status and record its boluses. Closing the loop takes two more steps, in two places: turn Control-IQ off in the Tandem Mobi app, then pick a basal control mode here in Trio's pump settings."
            )
        case .tslimX2:
            return String(
                localized: "Trio can now read this t:slim X2's status and record its boluses. The t:slim X2 has no remote temp-rate command, so the pump keeps managing basal with Control-IQ unless you enable the experimental microbolus-basal mode."
            )
        }
    }

    func finish() {
        didFinish?()
    }

    func cancel() {
        pumpManager.bluetooth.stopScan()
        didCancel?()
    }

    private func fail(_ message: String) {
        DispatchQueue.main.async {
            TandemHaptics.failure()
            self.errorMessage = message
            self.step = .codeEntry
        }
    }
}

struct TandemPairingView: View {
    @ObservedObject var viewModel: TandemPairingViewModel
    @FocusState private var codeFieldFocused: Bool

    /// CoreBluetooth's power state is not published anywhere the view can
    /// observe, so without this the "Bluetooth is off" card would still be
    /// there after the user turned it on.
    @State private var ticker = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    @State private var now = Date.now

    var body: some View {
        List {
            switch viewModel.step {
            case .intro:
                introSection
            case .scanning:
                scanningSection
            case .codeEntry,
                 .pairing:
                codeSection
            case .done:
                doneSection
            }
        }
        .tandemScreenBackground()
        .onReceive(ticker) { now = $0 }
        .navigationTitle(Text("Add Tandem Pump"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { viewModel.cancel() }
                    // The handshake runs to completion on its own queue and
                    // there is nothing to cancel it with, so the button says so
                    // by being unavailable rather than by doing nothing.
                    .disabled(viewModel.step == .pairing)
            }
        }
    }

    // MARK: - Intro

    @ViewBuilder private var introSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trio supports the Tandem Mobi and the t:slim X2.")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(
                    "On a Mobi, Trio can close the loop by setting temp basal rates on the pump. On a t:slim X2 the pump keeps managing basal itself, including Control-IQ, so Trio acts as a monitor and remote bolus interface unless the experimental microbolus-basal mode is enabled after pairing."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 2)
        }
        .tandemRowBackground()

        Section {
            step(
                1,
                String(
                    localized: "Make sure the pump allows a mobile app connection: on a t:slim X2 that is in the pump's own Bluetooth settings, on a Mobi it is in the Tandem Mobi app."
                )
            )
            step(
                2,
                String(localized: "Start pairing there, so the pump is waiting to accept a new device.")
            )
            step(
                3,
                String(
                    localized: "Have the pairing code to hand — 6 digits on a Mobi, 6 or 16 characters on a t:slim X2 depending on its software."
                )
            )
            step(4, String(localized: "Keep the pump next to this phone until pairing finishes."))
        } header: {
            Text("Before you start").glassCaption()
        }
        .tandemRowBackground()

        Section {
            TandemActionButton(
                title: String(localized: "Search for pump"),
                systemImage: "antenna.radiowaves.left.and.right"
            ) {
                viewModel.startScan()
            }
        }
        .tandemRowBackground()
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Color.insulin)
                .frame(width: 22, height: 22)
                .background(Color.insulin.opacity(0.15), in: Circle())
            Text(text)
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(localized: "Step \(number): \(text)"))
    }

    // MARK: - Scanning

    @ViewBuilder private var scanningSection: some View {
        Section {
            if !viewModel.isBluetoothPoweredOn {
                TandemCallout(
                    title: String(localized: "Bluetooth is off"),
                    message: String(
                        localized: "Trio cannot look for a pump until Bluetooth is on. Turn it on in Settings or Control Center, then search again."
                    ),
                    tone: .critical,
                    symbolName: "wifi.slash"
                )
            } else if viewModel.discoveredPumps.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Searching for pumps…")
                        .font(.subheadline)
                }
                .padding(.vertical, 4)
            }
            ForEach(viewModel.discoveredPumps) { pump in
                Button {
                    viewModel.select(pump: pump)
                } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(pump.name)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .foregroundStyle(Color.primary)
                            Text(pump.model?.localizedTitle ?? String(localized: "Unrecognized Tandem pump"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        signalBars(for: pump.rssi)
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .accessibilityLabel(
                    String(localized: "\(pump.name), signal \(signalDescription(for: pump.rssi))")
                )
            }
        } header: {
            Text("Pumps found").glassCaption()
        }
        .tandemRowBackground()

        Section {
            TandemCallout(
                title: String(localized: "Not seeing your pump?"),
                message: String(
                    localized: "The pump only advertises while it is waiting to pair, and it stops after a short while. Start pairing on the pump again, keep it within a few feet of the phone, and make sure it is not still connected to another phone."
                ),
                tone: .info,
                symbolName: "questionmark.circle.fill"
            ) {
                TandemActionButton(
                    title: String(localized: "Search again"),
                    systemImage: "arrow.clockwise",
                    emphasis: .bordered
                ) {
                    viewModel.startScan()
                }
            }
        }
        .tandemRowBackground()
    }

    /// Three bars from the advertisement's RSSI. Distance is the single thing
    /// that decides whether a pairing goes through, and the raw dBm number the
    /// old list showed does not tell most people that.
    private func signalBars(for rssi: Int) -> some View {
        let level = signalLevel(for: rssi)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(1 ... 3, id: \.self) { bar in
                Capsule()
                    .fill(bar <= level ? Color.insulin : Color.primary.opacity(0.15))
                    .frame(width: 3, height: CGFloat(4 + bar * 3))
            }
        }
        .accessibilityHidden(true)
    }

    private func signalLevel(for rssi: Int) -> Int {
        if rssi >= -60 { return 3 }
        if rssi >= -75 { return 2 }
        return 1
    }

    private func signalDescription(for rssi: Int) -> String {
        switch signalLevel(for: rssi) {
        case 3: return String(localized: "strong")
        case 2: return String(localized: "fair")
        default: return String(localized: "weak")
        }
    }

    // MARK: - Code entry

    @ViewBuilder private var codeSection: some View {
        Section {
            if let pump = viewModel.selectedPump {
                TandemInfoRow(
                    label: String(localized: "Pump"),
                    value: pump.model?.localizedTitle ?? pump.name
                )
            }
            Text(viewModel.codeInstruction)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Pairing code").glassCaption()
        }
        .tandemRowBackground()

        Section {
            TextField(viewModel.codeFieldPrompt, text: $viewModel.pairingCode)
                .font(.system(size: 22, weight: .semibold, design: .monospaced))
                .multilineTextAlignment(.center)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .keyboardType(viewModel.expectsSixDigitCode ? .numberPad : .default)
                .focused($codeFieldFocused)
                .disabled(viewModel.step == .pairing)
                .onChange(of: viewModel.pairingCode) { _, newValue in
                    // Cheap guard rail: the pump's code has a fixed length, and
                    // stopping the extra character here is friendlier than
                    // failing the handshake later.
                    let limit = viewModel.codeCharacterLimit
                    if newValue.count > limit {
                        viewModel.pairingCode = String(newValue.prefix(limit))
                    }
                }
                .onAppear { codeFieldFocused = true }
                .accessibilityLabel(String(localized: "Pairing code"))

            if let error = viewModel.errorMessage {
                TandemCallout(
                    title: String(localized: "Pairing did not complete"),
                    message: error,
                    tone: .critical
                )
            }
        }
        .tandemRowBackground()

        Section {
            Picker(String(localized: "Insulin"), selection: $viewModel.insulinType) {
                ForEach(viewModel.allowedInsulinTypes, id: \.self) { type in
                    Text(type.brandName).tag(type)
                }
            }
            .disabled(viewModel.step == .pairing)
        } header: {
            Text("Insulin type").glassCaption()
        }
        .tandemRowBackground()

        Section {
            if viewModel.step == .pairing {
                HStack(alignment: .top, spacing: 12) {
                    ProgressView()
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Pairing…")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        // The 6-digit flow runs an elliptic-curve key exchange,
                        // which is noticeably slower than the legacy
                        // challenge/response and looks like a hang if unexplained.
                        Text("Exchanging keys with the pump. This takes a few seconds — keep the pump next to the phone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } else {
                TandemActionButton(
                    title: String(localized: "Pair"),
                    systemImage: "link"
                ) {
                    codeFieldFocused = false
                    viewModel.pair()
                }
                .disabled(!viewModel.codeLooksComplete)

                Button {
                    viewModel.chooseAnotherPump()
                } label: {
                    Text("Choose a different pump")
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .tandemRowBackground()
    }

    // MARK: - Done

    @ViewBuilder private var doneSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.loopGreen)
                    Text("Paired")
                        .font(.headline)
                }
                Text(viewModel.pairedCapabilitySummary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
        }
        .tandemRowBackground()

        Section {
            TandemActionButton(title: String(localized: "Done"), systemImage: "checkmark") {
                viewModel.finish()
            }
        }
        .tandemRowBackground()
    }
}
