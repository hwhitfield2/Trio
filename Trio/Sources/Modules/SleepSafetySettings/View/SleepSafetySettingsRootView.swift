import SwiftUI
import Swinject

extension SleepSafetySettings {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private static let repeatMinuteOptions: [Decimal] = [5, 10, 15, 20, 30]
        private static let caregiverMinuteOptions: [Decimal] = [10, 15, 20, 30, 45, 60]

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.sleepSafetyEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable Sleep Safety")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Sleep Safety"),
                    miniHint: String(localized: "Extra overnight reminders for unacknowledged low glucose."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "During your scheduled sleep window, Trio can activate one of your existing Override presets and adds escalating reminders when a low glucose alert goes unacknowledged."
                        )
                        Text(
                            "Trio's normal alerts are unchanged; this only adds reminders on top of them. Opening the app or snoozing your alarms counts as acknowledgement."
                        )
                    },
                    headerText: String(localized: "Sleep Safety")
                )

                if state.sleepSafetyEnabled {
                    windowSection
                    overridePresetSection
                    escalationSection
                    caregiverSection
                    statusSection
                }
            }
            .listSectionSpacing(sectionSpacing)
            .sheet(isPresented: $shouldDisplayHint) {
                SettingInputHintView(
                    hintDetent: $hintDetent,
                    shouldDisplayHint: $shouldDisplayHint,
                    hintLabel: hintLabel ?? "",
                    hintText: selectedVerboseHint ?? AnyView(EmptyView()),
                    sheetTitle: String(localized: "Help", comment: "Help sheet title")
                )
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Sleep Safety")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }

        // MARK: - Sections

        private var windowSection: some View {
            Section {
                DatePicker(
                    "Window Start",
                    selection: windowBinding(for: $state.sleepWindowStartMinutes),
                    displayedComponents: .hourAndMinute
                )
                DatePicker(
                    "Window End",
                    selection: windowBinding(for: $state.sleepWindowEndMinutes),
                    displayedComponents: .hourAndMinute
                )
            } header: {
                Text("Sleep Window")
            } footer: {
                Text("The nightly time range sleep safety is active. A window that ends before it starts crosses midnight.")
            }
            .listRowBackground(Color.chart)
        }

        private var overridePresetSection: some View {
            Section {
                Picker(
                    selection: $state.sleepOverridePresetID,
                    label: Text("Override Preset")
                ) {
                    Text("None").tag("")
                    ForEach(state.presets) { preset in
                        Text(preset.name).tag(preset.id)
                    }
                }
                .disabled(state.presets.isEmpty)
            } header: {
                Text("Overnight Override")
            } footer: {
                if state.presets.isEmpty {
                    Text(
                        "No Override presets exist yet. Uses your existing Override presets. Manage them under Adjustments."
                    )
                } else {
                    Text(
                        "Activated automatically at the window start and ended at the window end. Uses your existing Override presets. Manage them under Adjustments. If another override is already running at the window start, it is kept and nothing is activated."
                    )
                }
            }
            .listRowBackground(Color.chart)
        }

        private var escalationSection: some View {
            Section {
                Picker(
                    selection: $state.sleepEscalationRepeatMinutes,
                    label: Text("Repeat Reminder Every")
                ) {
                    ForEach(Self.repeatMinuteOptions, id: \.self) { value in
                        Text("\(Int(truncating: value as NSNumber)) min").tag(value)
                    }
                }
            } header: {
                Text("Escalation")
            } footer: {
                Text(
                    "While glucose stays below your low alarm limit and no alert was acknowledged, an additional time-sensitive reminder is posted at this interval."
                )
            }
            .listRowBackground(Color.chart)
        }

        private var caregiverSection: some View {
            Section {
                Toggle(isOn: $state.sleepCaregiverEscalationEnabled) {
                    Text("Escalate to Caregiver")
                }
                .disabled(!state.isTwilioEnabled)

                if state.sleepCaregiverEscalationEnabled, state.isTwilioEnabled {
                    Picker(
                        selection: $state.sleepCaregiverEscalationMinutes,
                        label: Text("Text Caregiver After")
                    ) {
                        ForEach(Self.caregiverMinuteOptions, id: \.self) { value in
                            Text("\(Int(truncating: value as NSNumber)) min").tag(value)
                        }
                    }
                }
            } header: {
                Text("Caregiver")
            } footer: {
                if state.isTwilioEnabled {
                    Text(
                        "If a low stays unacknowledged for this long, one SMS per episode is sent to your Twilio recipients."
                    )
                } else {
                    Text("Requires Twilio SMS to be configured under Services.")
                }
            }
            .listRowBackground(Color.chart)
        }

        private var statusSection: some View {
            Section {
                HStack {
                    Text("Sleep window active now")
                    Spacer()
                    Image(systemName: state.isWindowActiveNow ? "moon.zzz.fill" : "sun.max")
                        .foregroundColor(state.isWindowActiveNow ? .purple : .secondary)
                    Text(state.isWindowActiveNow ? "Yes" : "No")
                        .foregroundColor(.secondary)
                }
            } footer: {
                Text(
                    "How it works: 1. Trio's normal low alarm fires as usual. 2. If it stays unacknowledged, additional reminders repeat at your chosen interval. 3. Optionally, a caregiver is texted once per episode. Trio's normal alerts are unchanged; this only adds reminders."
                )
            }
            .listRowBackground(Color.chart)
        }

        // MARK: - Minutes <-> Date conversion for the hour-and-minute pickers

        private func windowBinding(for minutes: Binding<Decimal>) -> Binding<Date> {
            Binding(
                get: { Self.date(fromMinutesSinceMidnight: minutes.wrappedValue) },
                set: { minutes.wrappedValue = Self.minutesSinceMidnight(from: $0) }
            )
        }

        private static func date(fromMinutesSinceMidnight minutes: Decimal) -> Date {
            let totalMinutes = Int(truncating: minutes as NSNumber)
            var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
            components.hour = totalMinutes / 60
            components.minute = totalMinutes % 60
            return Calendar.current.date(from: components) ?? Date()
        }

        private static func minutesSinceMidnight(from date: Date) -> Decimal {
            let components = Calendar.current.dateComponents([.hour, .minute], from: date)
            return Decimal((components.hour ?? 0) * 60 + (components.minute ?? 0))
        }
    }
}
