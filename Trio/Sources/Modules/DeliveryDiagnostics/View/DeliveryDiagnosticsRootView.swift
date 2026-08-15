import SwiftUI
import Swinject

extension DeliveryDiagnostics {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private let byteFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        var body: some View {
            List {
                explainerSection
                exportSection
                contentsSection

                Section {
                    Text(
                        "The file is CSV and contains therapy data — treat it like the rest of your diabetes data when sharing it."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Delivery Diagnostics")
            .navigationBarTitleDisplayMode(.automatic)
        }

        // MARK: - Sections

        private var explainerSection: some View {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        "If insulin feels too slow or too weak, this export collects everything needed to tell which of three things is happening."
                    )
                    Text(
                        "Trio never asked for more — the algorithm's requested insulin sits next to every setting that caps it, so a low Max Bolus or an SMB limit shows up immediately."
                    )
                    Text(
                        "Trio asked and the dose was cut or dropped — commands that were clamped, rejected by the pump, or never sent at all. None of these write pump history, so they are invisible everywhere else."
                    )
                    Text(
                        "Trio asked and the pump was slow — how long each command took to reach the pump, and any gaps between loop cycles."
                    )
                }
                .font(.subheadline)
            }
            .listRowBackground(Color.chart)
        }

        private var exportSection: some View {
            Section(
                header: Text("Export").glassCaption(),
                footer: Text(
                    "Command timing is recorded from the moment this build was installed, and kept for 14 days. Cycles, pump events, and loop history come from Trio's existing database and reach back as far as it does."
                ),
                content: {
                    Picker("History", selection: $state.window) {
                        ForEach(DeliveryDiagnosticsWindow.allCases) { window in
                            Text(window.displayName).tag(window)
                        }
                    }

                    Button {
                        state.exportDiagnostics()
                    } label: {
                        HStack {
                            Text("Export Delivery Diagnostics")
                            Spacer()
                            if state.isExporting {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(state.isExporting)

                    if let url = state.exportedFileURL {
                        ShareLink(item: url) {
                            HStack {
                                Image(systemName: "square.and.arrow.up")
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                    Text(byteFormatter.string(fromByteCount: Int64(size)))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if let message = state.exportErrorMessage {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            )
            .listRowBackground(Color.chart)
        }

        private var contentsSection: some View {
            Section(
                header: Text("What's In The File").glassCaption(),
                content: {
                    VStack(alignment: .leading, spacing: 8) {
                        fileSection(
                            "summary",
                            "Headline counts — SMBs requested against delivered, failed and never-sent commands, command latency median/p95/max, and the longest gap between loop cycles."
                        )
                        fileSection(
                            "settings",
                            "Every setting that limits delivery: Max Bolus, Max Basal, Max IOB, each SMB toggle and minute limit, bolus increment, insulin curve and peak, basal profile totals, and any scheduled delivery caps."
                        )
                        fileSection(
                            "cycles",
                            "One row per loop cycle: glucose, IOB, COB, the insulin required, what was recommended, whether it was enacted and how late — plus the algorithm's own reason text."
                        )
                        fileSection(
                            "commands",
                            "Every delivery command issued, with how long the pump took to answer and why it failed if it did."
                        )
                        fileSection(
                            "pump_events",
                            "What the pump itself reported delivering, as ground truth against the commands above."
                        )
                        fileSection(
                            "loops",
                            "Loop cycle timing, so late insulin from missed cycles is distinguishable from late insulin from slow commands."
                        )
                    }
                    .font(.footnote)
                }
            )
            .listRowBackground(Color.chart)
        }

        private func fileSection(_ name: String, _ description: String) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.footnote.monospaced()).bold()
                Text(description).foregroundStyle(.secondary)
            }
        }
    }
}
