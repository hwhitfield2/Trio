import SwiftUI
import Swinject

extension TwilioConfig {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var displayPickerUrgentLow: Bool = false
        @State private var isSendingTest: Bool = false
        @State private var testResultMessage: String?
        @State private var showTestResult: Bool = false
        @State private var newRecipientNumber: String = ""
        @State private var editingRecipientIndex: Int?
        @State private var editedRecipientNumber: String = ""

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.twilioEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable Twilio SMS Alerts")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Twilio SMS Alerts"),
                    miniHint: String(localized: "Send SMS alerts to caregivers automatically."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "Twilio is an SMS service with its own credentials and per-message costs. Unlike iMessage, it can send text messages fully automatically: when one of the conditions below is met, Trio calls the Twilio API and your caregivers receive an SMS without you touching the phone."
                        )
                        Text(
                            "You need a Twilio account with an SMS-capable phone number. Enter the Account SID and Auth Token from the Twilio console below; they are stored securely in the iOS keychain."
                        )
                        Text(
                            "Note: sending requires the app to be running and to have a network connection. Do not rely on it as your only safety net."
                        )
                    },
                    headerText: String(localized: "Twilio SMS Alerts")
                )

                if state.twilioEnabled {
                    credentialsSection
                    recipientsSection
                    conditionsSection
                    urgentLowThresholdSection
                    cooldownSection
                    testSection
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
            .alert(
                String(localized: "Twilio Test"),
                isPresented: $showTestResult,
                actions: { Button("OK", role: .cancel) {} },
                message: { Text(testResultMessage ?? "") }
            )
            .alert(
                String(localized: "Edit Number"),
                isPresented: Binding(
                    get: { editingRecipientIndex != nil },
                    set: { if !$0 { editingRecipientIndex = nil } }
                )
            ) {
                TextField(String(localized: "Number"), text: $editedRecipientNumber)
                    .keyboardType(.phonePad)
                Button(String(localized: "Save")) {
                    if let index = editingRecipientIndex {
                        state.updateRecipient(at: index, to: editedRecipientNumber)
                    }
                    editingRecipientIndex = nil
                }
                Button(String(localized: "Cancel"), role: .cancel) {
                    editingRecipientIndex = nil
                }
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Twilio SMS")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }

        private var credentialsSection: some View {
            Section {
                HStack {
                    Image(systemName: "number")
                    TextField(String(localized: "Account SID"), text: $state.accountSID)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                }
                HStack {
                    Image(systemName: "key")
                    SecureField(String(localized: "Auth Token"), text: $state.authToken)
                        .textContentType(.password)
                        .autocorrectionDisabled(true)
                        .textInputAutocapitalization(.never)
                    if !state.authToken.isEmpty {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                HStack {
                    Image(systemName: "phone.arrow.up.right")
                    TextField(String(localized: "Twilio Phone Number"), text: $state.twilioFromNumber)
                        .keyboardType(.phonePad)
                        .autocorrectionDisabled(true)
                }
            } header: {
                Text("Twilio Credentials")
            } footer: {
                Text(
                    "Find the Account SID and Auth Token in the Twilio console at twilio.com. The phone number is your SMS-capable Twilio number in international format, e.g. +15551234567. Credentials are stored securely in the iOS keychain."
                )
            }
            .listRowBackground(Color.chart)
        }

        private var recipientsSection: some View {
            Section {
                ForEach(Array(state.parsedRecipients.enumerated()), id: \.offset) { index, number in
                    HStack {
                        Image(systemName: "person")
                        Text(number)
                        Spacer()
                        Button {
                            editingRecipientIndex = index
                            editedRecipientNumber = number
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Edit number")

                        Button {
                            state.removeRecipients(at: IndexSet(integer: index))
                        } label: {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Delete number")
                    }
                }
                .onDelete { offsets in
                    state.removeRecipients(at: offsets)
                }

                HStack {
                    Image(systemName: "plus.circle.fill")
                        .foregroundStyle(.green)
                    TextField(String(localized: "Add number, e.g. +15551234567"), text: $newRecipientNumber)
                        .keyboardType(.phonePad)
                        .autocorrectionDisabled(true)
                        .onSubmit { addNewRecipient() }
                    Button(String(localized: "Add")) {
                        addNewRecipient()
                    }
                    .buttonStyle(.borderless)
                    .disabled(newRecipientNumber.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            } header: {
                Text("Destination Numbers")
            } footer: {
                Text(
                    "The caregivers' phone numbers in international format, e.g. +15551234567. Each number is its own entry - add one at a time, tap the pencil to edit it, or the trash to remove it. Each recipient receives their own SMS."
                )
            }
            .listRowBackground(Color.chart)
        }

        private func addNewRecipient() {
            state.addRecipient(newRecipientNumber)
            newRecipientNumber = ""
        }

        private var conditionsSection: some View {
            Group {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.twilioSendUrgentLow,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Urgent Low Glucose")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Urgent Low Glucose"),
                    miniHint: String(localized: "Send an SMS at or below the urgent low threshold."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: ON").bold()
                        Text(
                            "Sends an SMS as soon as glucose falls to or below the Urgent Low Threshold. Urgent low alerts bypass the cooldown."
                        )
                    },
                    headerText: String(localized: "Send an SMS when")
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.twilioSendLow,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Low Glucose")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Low Glucose"),
                    miniHint: String(localized: "Send an SMS at or below the low alarm limit."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: ON").bold()
                        Text(
                            "Sends an SMS when glucose falls to or below the Low Glucose Alarm Limit configured under Notifications > Trio Notifications."
                        )
                    }
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.twilioSendHigh,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "High Glucose")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "High Glucose"),
                    miniHint: String(localized: "Send an SMS at or above the high alarm limit."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "Sends an SMS when glucose rises to or above the High Glucose Alarm Limit configured under Notifications > Trio Notifications."
                        )
                    }
                )

                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.twilioSendLoopFailure,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Loop Failure")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Loop Failure"),
                    miniHint: String(localized: "Send an SMS when no loop has completed for 45 minutes."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "Sends an SMS when the loop has not completed for more than 45 minutes, for example because the pump is unreachable. The check runs whenever a new glucose reading arrives, so it also requires a working CGM connection."
                        )
                    }
                )
            }
        }

        private var urgentLowThresholdSection: some View {
            Section {
                VStack {
                    HStack {
                        Text("Urgent Low Threshold")

                        Spacer()

                        Group {
                            Text(
                                state.units == .mgdL ? state.twilioUrgentLowThreshold.description : state
                                    .twilioUrgentLowThreshold.formattedAsMmolL
                            )
                            .foregroundColor(!displayPickerUrgentLow ? .primary : .accentColor)

                            Text(state.units == .mgdL ? " mg/dL" : " mmol/L").foregroundColor(.secondary)
                        }
                    }
                    .onTapGesture {
                        displayPickerUrgentLow.toggle()
                    }

                    if displayPickerUrgentLow {
                        let setting = PickerSettingsProvider.shared.settings.lowGlucose

                        Picker(selection: $state.twilioUrgentLowThreshold, label: Text("")) {
                            ForEach(
                                PickerSettingsProvider.shared.generatePickerValues(from: setting, units: state.units),
                                id: \.self
                            ) { value in
                                let displayValue = state.units == .mgdL ? value.description : value.formattedAsMmolL
                                Text(displayValue).tag(value)
                            }
                        }
                        .pickerStyle(WheelPickerStyle())
                        .frame(maxWidth: .infinity)
                    }
                }.padding(.vertical)
            } footer: {
                Text("Glucose level at or below which an urgent low SMS is sent. Urgent low alerts bypass the cooldown.")
            }
            .listRowBackground(Color.chart)
        }

        private var cooldownSection: some View {
            Section {
                Picker(
                    selection: $state.twilioCooldownMinutes,
                    label: Text("Cooldown")
                ) {
                    ForEach(TwilioMessaging.Config.cooldownOptions, id: \.self) { value in
                        Text("\(Int(truncating: value as NSNumber)) min").tag(value)
                    }
                }
            } footer: {
                Text(
                    "Minimum time between two SMS alerts, so caregivers are not flooded with messages. Urgent low alerts ignore the cooldown. An alert that stays active is only sent once until it resolves."
                )
            }
            .listRowBackground(Color.chart)
        }

        private var testSection: some View {
            Section {
                Button {
                    isSendingTest = true
                    Task {
                        do {
                            try await state.sendTestMessage()
                            testResultMessage = String(localized: "Test SMS sent successfully.")
                        } catch {
                            testResultMessage = error.localizedDescription
                        }
                        isSendingTest = false
                        showTestResult = true
                    }
                } label: {
                    if isSendingTest {
                        HStack {
                            ProgressView()
                            Text("Sending…").padding(.leading, 8)
                        }
                    } else {
                        Label("Send Test SMS", systemImage: "paperplane.fill")
                    }
                }
                .disabled(isSendingTest || !state.isConfigured || state.parsedRecipients.isEmpty)
            } footer: {
                Text("Sends a test SMS with your current status to all destination numbers to verify the configuration.")
            }
            .listRowBackground(Color.chart)
        }
    }
}
