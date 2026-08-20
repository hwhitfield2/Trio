import SwiftUI
import Swinject
import UniformTypeIdentifiers

extension SettingsExport {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var showSettingsExport = false
        @State private var showExportError = false
        @State private var exportErrorMessage = ""
        @State private var exportedFileURL: URL?

        @State private var showImportFilePicker = false
        @State private var pendingBackup: TrioSettingsBackup?
        @State private var showImportConfirmation = false
        @State private var showImportError = false
        @State private var importErrorMessage = ""
        @State private var showImportSuccess = false
        @State private var importSuccessMessage = ""

        // Device setup transfer (dense matrix / QR sequence between two phones)
        @State private var deviceSetupCode: StateModel.DeviceSetupCode?
        @State private var showDeviceSetupPresenter = false
        @State private var isPreparingSetupCode = false
        @State private var showDeviceSetupScanner = false
        @State private var pendingTransfer: DeviceSetupTransfer?
        @State private var showTransferConfirmation = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    header: Text("Export Categories"),
                    content: {
                        // Select All toggle
                        HStack {
                            Button(action: {
                                state.toggleAllCategories(!state.allCategoriesSelected)
                            }) {
                                HStack {
                                    Image(systemName: state.allCategoriesSelected ? "checkmark.square.fill" : "square")
                                        .foregroundColor(state.allCategoriesSelected ? .blue : .secondary)
                                    Text(
                                        state
                                            .allCategoriesSelected ? String(localized: "Deselect All") :
                                            String(localized: "Select All")
                                    )
                                    .fontWeight(.bold)
                                    .foregroundColor(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(PlainButtonStyle())
                        }

                        // Individual category toggles
                        ForEach(SettingsExport.StateModel.ExportCategory.allCases) { category in
                            HStack {
                                Button(action: {
                                    if state.selectedCategories.contains(category) {
                                        state.selectedCategories.remove(category)
                                    } else {
                                        state.selectedCategories.insert(category)
                                    }
                                }) {
                                    HStack {
                                        Image(
                                            systemName: state.selectedCategories
                                                .contains(category) ? "checkmark.square.fill" : "square"
                                        )
                                        .foregroundColor(state.selectedCategories.contains(category) ? .blue : .secondary)

                                        Text(category.rawValue)

                                        Spacer()
                                    }
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                            .padding(.vertical, 2)
                        }
                    }
                ).listRowBackground(Color.chart)

                Section {
                    Button(action: {
                        Task {
                            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
                            impactHeavy.impactOccurred()
                            state.isExporting = true

                            switch await state.exportSelectedSettings() {
                            case let .success(fileURL):
                                if FileManager.default.fileExists(atPath: fileURL.path) {
                                    do {
                                        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
                                        let fileSize = attributes[.size] as? Int ?? 0

                                        if fileSize > 0 {
                                            exportedFileURL = fileURL
                                            // Stop spinner on successful export
                                            state.isExporting = false
                                            showSettingsExport = true
                                        } else {
                                            exportErrorMessage = "Export file is empty (0 bytes)"
                                            showExportError = true
                                            state.isExporting = false
                                        }
                                    } catch {
                                        exportErrorMessage = "Could not verify file attributes: \(error.localizedDescription)"
                                        showExportError = true
                                        // Stop spinner on error
                                        state.isExporting = false
                                    }
                                } else {
                                    exportErrorMessage = "Export file was created but could not be found at: \(fileURL.path)"
                                    showExportError = true
                                    // Stop spinner on error
                                    state.isExporting = false
                                }
                            case let .failure(error):
                                exportErrorMessage = error.localizedDescription
                                showExportError = true
                                // Stop spinner on error
                                state.isExporting = false
                            }
                        }
                    }, label: {
                        if state.isExporting {
                            HStack {
                                ProgressView().padding(.trailing, 10)
                                Text("Exporting...")
                            }
                        } else {
                            Text("Export Settings")
                        }

                    })
                        .disabled(state.selectedCategories.isEmpty)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .tint(.white)
                }.listRowBackground(
                    state.selectedCategories.isEmpty ? Color(.systemGray4) : Color(.systemBlue)
                )

                Section(
                    header: Text("Backup & Restore"),
                    footer: Text(
                        "A backup file contains all Trio settings, therapy profiles and presets in a machine-readable format and can be imported again — for example on a new phone. The CSV export above is a human-readable report and cannot be imported."
                    ),
                    content: {
                        Button(action: {
                            Task { await exportBackup() }
                        }, label: {
                            if state.isExporting {
                                HStack {
                                    ProgressView().padding(.trailing, 10)
                                    Text("Exporting...")
                                }
                            } else {
                                Label("Export Backup File", systemImage: "square.and.arrow.up")
                            }
                        })

                        Button(action: {
                            showImportFilePicker = true
                        }, label: {
                            if state.isImporting {
                                HStack {
                                    ProgressView().padding(.trailing, 10)
                                    Text("Importing...")
                                }
                            } else {
                                Label("Import Backup File", systemImage: "square.and.arrow.down")
                            }
                        })
                            .disabled(state.isImporting)
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("Set Up a New Device"),
                    footer: Text(
                        "Moves everything to a new phone by QR code: all settings, therapy profiles, presets and remote control — including paired followers, which switch to the new device automatically. Show the code on this phone and scan it with the new one. Afterwards, turn off remote control on the old phone."
                    ),
                    content: {
                        Button(action: {
                            Task { await prepareDeviceSetup() }
                        }, label: {
                            if isPreparingSetupCode {
                                HStack {
                                    ProgressView().padding(.trailing, 10)
                                    Text("Preparing...")
                                }
                            } else {
                                Label("Show Setup Code", systemImage: "qrcode")
                            }
                        })
                            .disabled(isPreparingSetupCode)

                        Button(action: {
                            showDeviceSetupScanner = true
                        }, label: {
                            Label("Scan Setup Code", systemImage: "qrcode.viewfinder")
                        })
                            .disabled(state.isImporting)
                    }
                ).listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationTitle("Export & Import Settings")
            .navigationBarTitleDisplayMode(.automatic)
//            // TODO: implement help sheet
//            .toolbar {
//                ToolbarItem(placement: .topBarTrailing) {
//                    Button(
//                        action: {
//                            state.isHelpSheetPresented.toggle()
//                        },
//                        label: {
//                            Image(systemName: "questionmark.circle")
//                        }
//                    )
//                }
//            }
//            .sheet(isPresented: $state.isHelpSheetPresented) {
//                NavigationStack {
//                    List {
//                        Text("Hello World!")
//                    }
//                }
//                .padding()
//                .presentationDetents(
//                    [.fraction(0.9), .large],
//                    selection: $state.helpSheetDetent
//                )
//            }
            .sheet(isPresented: $showSettingsExport) {
                if let fileURL = exportedFileURL {
                    ShareSheet(activityItems: [fileURL])
                }
            }
            .sheet(isPresented: $showDeviceSetupPresenter) {
                if let deviceSetupCode {
                    DeviceSetupPresenterView(code: deviceSetupCode) {
                        showDeviceSetupPresenter = false
                        self.deviceSetupCode = nil
                    }
                    .interactiveDismissDisabled()
                }
            }
            .sheet(isPresented: $showDeviceSetupScanner) {
                DeviceSetupScannerView(
                    onTransfer: { transfer in
                        showDeviceSetupScanner = false
                        // The scanner sheet is still dismissing; a confirmation
                        // presented during the dismissal is silently dropped.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            if let validationError = state.validateDeviceSetup(transfer) {
                                importErrorMessage = validationError.localizedDescription
                                showImportError = true
                            } else {
                                pendingTransfer = transfer
                                showTransferConfirmation = true
                            }
                        }
                    },
                    onCancel: { showDeviceSetupScanner = false }
                )
            }
            .alert(
                "Set Up This Device?",
                isPresented: $showTransferConfirmation,
                presenting: pendingTransfer
            ) { transfer in
                Button("Cancel", role: .cancel) { pendingTransfer = nil }
                Button("Set Up", role: .destructive) {
                    pendingTransfer = nil
                    Task { await applyTransfer(transfer) }
                }
            } message: { transfer in
                Text(transferConfirmationText(for: transfer))
            }
            .alert("Export Error", isPresented: $showExportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(exportErrorMessage)
            }
            .fileImporter(
                isPresented: $showImportFilePicker,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false
            ) { result in
                // Read the file immediately — the security-scoped URL is only valid now.
                let readResult: Result<TrioSettingsBackup, Error>
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    readResult = state.readBackup(from: url).mapError { $0 as Error }
                case let .failure(error):
                    readResult = .failure(error)
                }

                // The picker sheet is still dismissing when this closure runs; an alert
                // presented during that dismissal is silently dropped. Defer until the
                // dismissal has completed.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    switch readResult {
                    case let .success(backup):
                        pendingBackup = backup
                        showImportConfirmation = true
                    case let .failure(error):
                        importErrorMessage = error.localizedDescription
                        showImportError = true
                    }
                }
            }
            .alert(
                "Import Settings?",
                isPresented: $showImportConfirmation,
                presenting: pendingBackup
            ) { backup in
                Button("Cancel", role: .cancel) { pendingBackup = nil }
                Button("Import", role: .destructive) {
                    pendingBackup = nil
                    Task { await importBackup(backup) }
                }
            } message: { backup in
                Text(importConfirmationText(for: backup))
            }
            .alert("Import Complete", isPresented: $showImportSuccess) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importSuccessMessage)
            }
            .alert("Import Error", isPresented: $showImportError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importErrorMessage)
            }
        }

        private func exportBackup() async {
            let impactHeavy = UIImpactFeedbackGenerator(style: .heavy)
            impactHeavy.impactOccurred()

            switch await state.exportBackup() {
            case let .success(fileURL):
                exportedFileURL = fileURL
                showSettingsExport = true
            case let .failure(error):
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
        }

        private func importBackup(_ backup: TrioSettingsBackup) async {
            // Give the confirmation alert time to finish dismissing — presenting the
            // result alert while it is still animating away silently drops it.
            try? await Task.sleep(nanoseconds: 600_000_000)

            switch await state.applyBackup(backup) {
            case let .success(summary):
                importSuccessMessage = summary.message
                showImportSuccess = true
            case let .failure(error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }

        private func prepareDeviceSetup() async {
            isPreparingSetupCode = true
            defer { isPreparingSetupCode = false }

            switch await state.makeDeviceSetupCode() {
            case let .success(code):
                deviceSetupCode = code
                showDeviceSetupPresenter = true
            case let .failure(error):
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
        }

        private func applyTransfer(_ transfer: DeviceSetupTransfer) async {
            // Give the confirmation alert time to finish dismissing — presenting the
            // result alert while it is still animating away silently drops it.
            try? await Task.sleep(nanoseconds: 600_000_000)

            switch await state.applyDeviceSetup(transfer) {
            case let .success(summary):
                importSuccessMessage = summary.message
                showImportSuccess = true
            case let .failure(error):
                importErrorMessage = error.localizedDescription
                showImportError = true
            }
        }

        private func transferConfirmationText(for transfer: DeviceSetupTransfer) -> String {
            var lines: [String] = []

            if let hostName = transfer.hostName {
                lines.append(String(localized: "Setup code from \(hostName)."))
            }
            if let backup = transfer.backup {
                lines.append(importConfirmationText(for: backup))
            }
            if let remoteControl = transfer.remoteControl {
                let followerCount = remoteControl.followers?.count ?? 0
                if followerCount > 0 {
                    lines.append(String(
                        localized: "Also moves remote control with \(followerCount) paired follower(s) to this phone. Turn off remote control on the old phone afterwards — until then followers may still reach it."
                    ))
                } else {
                    lines.append(String(localized: "Also moves the remote control configuration to this phone."))
                }
            }
            return lines.joined(separator: "\n\n")
        }

        private func importConfirmationText(for backup: TrioSettingsBackup) -> String {
            var contents: [String] = []
            if backup.trioSettings != nil { contents.append(String(localized: "Trio settings")) }
            if backup.preferences != nil { contents.append(String(localized: "algorithm preferences")) }
            if backup.pumpSettings != nil { contents.append(String(localized: "delivery limits")) }
            if backup.basalProfile != nil { contents.append(String(localized: "basal rates")) }
            if backup.insulinSensitivities != nil { contents.append(String(localized: "insulin sensitivities")) }
            if backup.carbRatios != nil { contents.append(String(localized: "carb ratios")) }
            if backup.bgTargets != nil { contents.append(String(localized: "glucose targets")) }
            let presetCount = (backup.tempTargetPresets?.count ?? 0) + (backup.overridePresets?.count ?? 0) +
                (backup.mealPresets?.count ?? 0)
            if presetCount > 0 { contents.append(String(localized: "\(presetCount) preset(s)")) }

            var lines: [String] = []
            if let exportDate = backup.exportDate {
                let dateString = DateFormatter.localizedString(from: exportDate, dateStyle: .medium, timeStyle: .short)
                if let appVersion = backup.appVersion {
                    lines.append(String(localized: "Backup created \(dateString) with Trio \(appVersion)."))
                } else {
                    lines.append(String(localized: "Backup created \(dateString)."))
                }
            }
            lines.append(String(localized: "Contains: \(contents.joined(separator: ", "))."))
            lines.append(String(
                localized: "Importing overwrites your current settings. Your CGM selection and closed loop setting will not be changed. Review all settings afterwards, especially your therapy settings."
            ))
            return lines.joined(separator: "\n\n")
        }
    }
}

private struct ExportCategoryRow: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 2)
    }
}
