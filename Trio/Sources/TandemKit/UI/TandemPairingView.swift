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
        self.allowedInsulinTypes = allowedInsulinTypes.isEmpty ? [.novolog, .humalog, .apidra, .fiasp, .lyumjev] :
            allowedInsulinTypes
    }

    /// Model of the pump the user picked, as far as its advertised name says.
    var selectedModel: TandemPumpModel? {
        selectedPump?.model
    }

    /// A Mobi only ever shows a 6-digit code, so its entry field can be
    /// numeric-only and its instructions specific.
    var expectsSixDigitCode: Bool {
        selectedModel == .mobi
    }

    var codeFieldPrompt: String {
        expectsSixDigitCode
            ? String(localized: "6-digit code from the pump")
            : String(localized: "Pairing code from the pump")
    }

    func startScan() {
        step = .scanning
        discoveredPumps = []
        pumpManager.bluetooth.startScan { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if !self.discoveredPumps.contains(where: { $0.id == result.id }) {
                    self.discoveredPumps.append(result)
                }
            }
        }
    }

    func select(pump: TandemScanResult) {
        selectedPump = pump
        pumpManager.bluetooth.stopScan()
        step = .codeEntry
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
                self.step = .done
            }
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
            self.errorMessage = message
            self.step = .codeEntry
        }
    }
}

struct TandemPairingView: View {
    @ObservedObject var viewModel: TandemPairingViewModel

    var body: some View {
        Form {
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
        .navigationTitle(Text("Tandem Pump"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(String(localized: "Cancel")) { viewModel.cancel() }
            }
        }
    }

    private var introSection: some View {
        Group {
            Section {
                Text(
                    "Trio supports the Tandem Mobi and the t:slim X2. On a Mobi, Trio can close the loop by setting temp basal rates on the pump. On a t:slim X2 the pump keeps managing basal itself (including Control-IQ), so Trio acts as a monitor and remote bolus interface unless the experimental microbolus-basal mode is enabled after pairing."
                )
                .font(.footnote)
            }
            Section(header: Text("Before you start")) {
                Text("1. On the pump, enable the mobile app connection in its Bluetooth settings.")
                Text("2. Start pairing on the pump so it is ready to accept a new device.")
                Text(
                    "3. Have the pairing code ready: the Tandem Mobi uses a 6-digit code, and the t:slim X2 uses a 16-character code on software 7.1–7.6 or a 6-digit code on 7.7 and newer."
                )
            }
            .font(.footnote)
            Section {
                Button {
                    viewModel.startScan()
                } label: {
                    Text("Search for Pump")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }

    private var scanningSection: some View {
        Section(header: Text("Pumps found")) {
            if viewModel.discoveredPumps.isEmpty {
                HStack {
                    ProgressView()
                    Text("Searching…").padding(.leading)
                }
            }
            ForEach(viewModel.discoveredPumps) { pump in
                Button {
                    viewModel.select(pump: pump)
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(pump.name)
                            if let model = pump.model {
                                Text(model.localizedTitle)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer()
                        Text("\(pump.rssi) dB").foregroundColor(.secondary)
                    }
                }
            }
        }
    }

    private var codeSection: some View {
        Group {
            Section(header: Text("Pairing code")) {
                TextField(viewModel.codeFieldPrompt, text: $viewModel.pairingCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .keyboardType(viewModel.expectsSixDigitCode ? .numberPad : .default)
                if let error = viewModel.errorMessage {
                    Text(error).foregroundColor(.red).font(.footnote)
                }
            }
            Section(header: Text("Insulin type")) {
                Picker(String(localized: "Insulin"), selection: $viewModel.insulinType) {
                    ForEach(viewModel.allowedInsulinTypes, id: \.self) { type in
                        Text(type.brandName).tag(type)
                    }
                }
            }
            Section {
                if viewModel.step == .pairing {
                    HStack {
                        ProgressView()
                        VStack(alignment: .leading) {
                            Text("Pairing…")
                            // The 6-digit flow runs an elliptic-curve key
                            // exchange, which is noticeably slower than the
                            // legacy challenge/response.
                            Text("This can take a few seconds. Keep the pump close by.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(.leading)
                    }
                } else {
                    Button {
                        viewModel.pair()
                    } label: {
                        Text("Pair")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }
        }
    }

    private var doneSection: some View {
        Group {
            Section {
                Label(String(localized: "Paired successfully"), systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            }
            Section {
                Button {
                    viewModel.finish()
                } label: {
                    Text("Done")
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}
