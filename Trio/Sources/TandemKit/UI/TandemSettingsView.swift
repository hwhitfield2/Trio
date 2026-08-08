import LoopKit
import SwiftUI

final class TandemSettingsViewModel: ObservableObject {
    @Published var refreshing = false
    @Published var remoteBolusEnabled: Bool
    @Published var showRemoteBolusWarning = false
    @Published var showDeleteConfirmation = false

    let pumpManager: TandemPumpManager

    var didFinish: (() -> Void)?
    var didDeletePump: (() -> Void)?

    init(pumpManager: TandemPumpManager) {
        self.pumpManager = pumpManager
        remoteBolusEnabled = pumpManager.state.remoteBolusEnabled
    }

    var state: TandemPumpState { pumpManager.state }

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
}

struct TandemSettingsView: View {
    @ObservedObject var viewModel: TandemSettingsViewModel

    var body: some View {
        Form {
            statusSection
            deliverySection
            remoteBolusSection
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
        .alert(String(localized: "Remove pump?"), isPresented: $viewModel.showDeleteConfirmation) {
            Button(String(localized: "Cancel"), role: .cancel) {}
            Button(String(localized: "Remove"), role: .destructive) { viewModel.didDeletePump?() }
        } message: {
            Text("Trio will forget this pump. Delivery on the pump itself is not affected.")
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
                "Basal delivery is managed entirely by the pump\(viewModel.state.controlIQEnabled ? " (Control-IQ is on)" : ""). Trio records what the pump reports but cannot adjust basal on the t:slim X2, so closed loop is unavailable with this pump."
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
