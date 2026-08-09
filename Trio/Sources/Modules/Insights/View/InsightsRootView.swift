import SwiftUI
import Swinject

extension Insights {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private var severitiesInOrder: [InsightSeverity] {
            InsightSeverity.allCases.sorted(by: >)
        }

        var body: some View {
            List {
                Section(
                    header: Text("Analysis Period"),
                    footer: Text("Patterns are recomputed from your on-device history for the selected period.")
                ) {
                    Picker("Period", selection: $state.selectedPeriodDays) {
                        Text("14 days").tag(14)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Color.chart)

                if state.isAnalyzing, !state.hasAnalyzed {
                    Section {
                        HStack {
                            Spacer()
                            ProgressView()
                            Spacer()
                        }
                    }
                    .listRowBackground(Color.chart)
                } else if state.cards.isEmpty, state.hasAnalyzed {
                    Section {
                        ContentUnavailableView(
                            String(localized: "No Patterns Found"),
                            systemImage: "checkmark.seal",
                            description: Text(
                                "No recurring patterns stood out in the selected period. Logging meals with notes helps the meal detectors find more."
                            )
                        )
                    }
                    .listRowBackground(Color.chart)
                } else {
                    ForEach(severitiesInOrder, id: \.self) { severity in
                        let cards = state.cards.filter { $0.severity == severity }
                        if !cards.isEmpty {
                            Section(header: Text(severity.displayName)) {
                                ForEach(cards) { card in
                                    InsightCardView(card: card)
                                }
                            }
                            .listRowBackground(Color.chart)
                        }
                    }
                }

                Section {} footer: {
                    Text(
                        "How this works: Insights are computed on this device from your recent glucose readings, carb entries, and algorithm decisions. They highlight recurring patterns only and are not medical advice. Always discuss any therapy changes with your care team."
                    )
                }
                .listRowBackground(Color.clear)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .refreshable {
                await state.analyze(force: true)
            }
            .onAppear(perform: configureView)
            .navigationBarTitle("Insights")
            .navigationBarTitleDisplayMode(.automatic)
        }
    }
}
