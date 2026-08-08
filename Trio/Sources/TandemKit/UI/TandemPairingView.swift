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
        guard normalized.count == 16 else {
            errorMessage = String(
                localized: "The pairing code should have 16 letters and numbers. If your pump shows a 6-digit code, its software version is not supported yet."
            )
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

            switch self.pumpManager.session.authenticate(pairingCode: normalized) {
            case .success:
                self.pumpManager.completePairing(
                    peripheralIdentifier: pump.id,
                    pairingCode: normalized,
                    insulinType: self.insulinType
                )
                DispatchQueue.main.async {
                    self.step = .done
                }
            case let .failure(error):
                self.fail(error.localizedDescription)
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
        .navigationTitle(Text("Tandem t:slim X2"))
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
                    "Trio connects to the t:slim X2 as a monitor and remote bolus interface. The pump keeps managing basal delivery itself (including Control-IQ). Trio cannot run a closed loop with this pump."
                )
                .font(.footnote)
            }
            Section(header: Text("Before you start")) {
                Text("1. On the pump, open Options → Device Settings → Bluetooth Settings and enable Mobile Connection.")
                Text("2. Choose \"Pair Device\" so the pump shows its pairing code.")
                Text("3. Pumps with software 7.1–7.6 show a 16-character code, which Trio supports. A 6-digit code means unsupported newer software.")
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
                        Text(pump.name)
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
                TextField(String(localized: "16-character code from the pump"), text: $viewModel.pairingCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
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
                        Text("Pairing…").padding(.leading)
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
