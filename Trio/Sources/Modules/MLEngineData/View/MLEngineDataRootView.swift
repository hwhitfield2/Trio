import SwiftUI
import Swinject

extension MLEngineData {
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
                Section(
                    header: Text("Training Data Export"),
                    content: {
                        Picker("History", selection: $state.exportDaysBack) {
                            Text("30 days").tag(30)
                            Text("60 days").tag(60)
                            Text("90 days").tag(90)
                        }

                        Button {
                            state.exportTrainingData()
                        } label: {
                            HStack {
                                Text("Export Training Data")
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
                                }
                            }
                        }

                        if let message = state.exportErrorMessage {
                            Text(message)
                                .font(.footnote)
                                .foregroundStyle(.red)
                        }
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("Decision Audit Records"),
                    footer: Text(
                        "One record per dosing cycle: who decided (algorithm, versions, caps in force), what was proposed and enacted, which path the decision took, when, why (predictions and binding constraints), and how. Files rotate daily and are kept for 90 days."
                    ),
                    content: {
                        if state.auditFileURLs.isEmpty {
                            Text("No audit records yet. Records appear after the next loop cycle.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(state.auditFileURLs, id: \.absoluteString) { url in
                                ShareLink(item: url) {
                                    HStack {
                                        Text(url.lastPathComponent)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer()
                                        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                                            Text(byteFormatter.string(fromByteCount: Int64(size)))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                        Image(systemName: "square.and.arrow.up")
                                            .font(.footnote)
                                    }
                                }
                            }
                        }
                    }
                ).listRowBackground(Color.chart)

                Section {
                    Text(
                        "Exports feed the offline training pipeline (ml/ in the repo). See docs/ML_DOSING_REPLACEMENT_PLAN.md for the full architecture. No model doses insulin from this screen — it is data out only."
                    )
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                }.listRowBackground(Color.clear)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .onAppear { state.loadAuditFiles() }
            .navigationBarTitle("ML Data & Audit")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
