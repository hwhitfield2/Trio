import SwiftUI
import Swinject

extension DeliveryCapEditor {
    struct RootView: BaseView {
        let resolver: Resolver

        @State var state = StateModel()

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                Section(
                    footer: Text(
                        "During a window the loop keeps running — determinations, forecasts, and audit records are produced every cycle — but delivery is capped at enactment. Max Basal 0 and Max SMB 0 means no insulin from the loop: SMBs are suppressed and a zero temp overrides scheduled basal. A cap below the current temp or scheduled basal actively enforces itself. Windows may cross midnight; overlapping windows apply the most restrictive values. Manual boluses are not affected."
                    ),
                    content: {
                        if state.windows.isEmpty {
                            Text("No delivery cap windows configured.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach($state.windows) { $window in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    DatePicker(
                                        "From",
                                        selection: timeBinding($window.startMinutes),
                                        displayedComponents: .hourAndMinute
                                    )
                                    DatePicker(
                                        "To",
                                        selection: timeBinding($window.endMinutes),
                                        displayedComponents: .hourAndMinute
                                    )
                                }
                                Stepper(
                                    value: doubleBinding($window.maxBasalRate),
                                    in: 0 ... 10,
                                    step: 0.05
                                ) {
                                    HStack {
                                        Text("Max Basal")
                                        Spacer()
                                        Text("\(formatted(window.maxBasalRate)) U/hr")
                                            .foregroundStyle(window.maxBasalRate == 0 ? Color.red : Color.secondary)
                                    }
                                }
                                Stepper(
                                    value: doubleBinding($window.maxSMB),
                                    in: 0 ... 5,
                                    step: 0.05
                                ) {
                                    HStack {
                                        Text("Max SMB")
                                        Spacer()
                                        Text("\(formatted(window.maxSMB)) U")
                                            .foregroundStyle(window.maxSMB == 0 ? Color.red : Color.secondary)
                                    }
                                }
                            }
                            .padding(.vertical, 4)
                        }
                        .onDelete { state.removeWindows(at: $0) }

                        Button {
                            state.addWindow()
                        } label: {
                            Label("Add Window", systemImage: "plus")
                        }
                    }
                ).listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .onChange(of: state.windows) { state.save() }
            .navigationBarTitle("Scheduled Delivery Caps")
            .navigationBarTitleDisplayMode(.automatic)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { EditButton() } }
        }

        private func timeBinding(_ minutes: Binding<Int>) -> Binding<Date> {
            Binding(
                get: {
                    let midnight = Calendar.current.startOfDay(for: Date())
                    return Calendar.current.date(byAdding: .minute, value: minutes.wrappedValue, to: midnight) ?? midnight
                },
                set: { newDate in
                    let components = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                    minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                }
            )
        }

        private func doubleBinding(_ value: Binding<Decimal>) -> Binding<Double> {
            Binding(
                get: { Double(truncating: value.wrappedValue as NSDecimalNumber) },
                set: { value.wrappedValue = Decimal(Int(($0 * 100).rounded())) / 100 }
            )
        }

        private func formatted(_ value: Decimal) -> String {
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 0
            formatter.maximumFractionDigits = 2
            return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
        }
    }
}
