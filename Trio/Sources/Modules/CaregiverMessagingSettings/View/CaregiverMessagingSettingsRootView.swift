import MessageUI
import SwiftUI
import Swinject

extension CaregiverMessagingSettings {
    struct RootView: BaseView {
        let resolver: Resolver
        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0

        @State private var composedMessage = ""
        @State private var isPresentingComposer = false

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.caregiverMessagingEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable Caregiver Messaging")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Caregiver Messaging"),
                    miniHint: String(localized: "Share glucose updates with caregivers via Messages."),
                    verboseHint:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "Caregiver Messaging composes a status text with your latest glucose reading, trend and optionally IOB and COB, ready to send to your caregivers with the Messages app."
                        )
                        Text(
                            "Apple does not allow apps to send iMessages by themselves. Trio pre-fills the message and recipients — you confirm with a single tap on send."
                        )
                        Text(
                            "For fully automatic updates, create a personal automation in the Shortcuts app that uses the 'Get Caregiver Update' Trio action followed by the 'Send Message' action."
                        )
                    },
                    headerText: String(localized: "Caregiver Messaging")
                )

                if state.caregiverMessagingEnabled {
                    Section {
                        HStack {
                            Image(systemName: "person.2")
                            TextField(
                                String(localized: "Phone numbers or emails, comma-separated"),
                                text: $state.caregiverRecipients
                            )
                            .textContentType(.telephoneNumber)
                            .keyboardType(.emailAddress)
                            .autocorrectionDisabled(true)
                            .textInputAutocapitalization(.never)
                        }
                    } header: {
                        Text("Recipients")
                    } footer: {
                        Text(
                            "The caregivers' phone numbers or iMessage email addresses. Separate several recipients with commas."
                        )
                    }
                    .listRowBackground(Color.chart)

                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.caregiverMessagesIncludeIOBCOB,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Include IOB and COB")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Include IOB and COB"),
                        miniHint: String(localized: "Add insulin and carbs on board to the message."),
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: ON").bold()
                            Text("When enabled, caregiver messages include your current insulin on board and carbs on board.")
                        }
                    )

                    SettingInputSection(
                        decimalValue: $decimalPlaceholder,
                        booleanValue: $state.caregiverAlertQuickAction,
                        shouldDisplayHint: $shouldDisplayHint,
                        selectedVerboseHint: Binding(
                            get: { selectedVerboseHint },
                            set: {
                                selectedVerboseHint = $0.map { AnyView($0) }
                                hintLabel = String(localized: "Text Caregiver from Alerts")
                            }
                        ),
                        units: state.units,
                        type: .boolean,
                        label: String(localized: "Text Caregiver from Alerts"),
                        miniHint: String(localized: "Add a 'Text Caregiver' button to glucose alarm notifications."),
                        verboseHint:
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Default: ON").bold()
                            Text(
                                "Adds a 'Text Caregiver' action to low and high glucose alarm notifications. Tapping it opens Trio with a pre-filled Messages sheet, so you can inform your caregivers with a single tap on send."
                            )
                        }
                    )

                    Section {
                        Button {
                            composedMessage = state.composeStatusMessage()
                            isPresentingComposer = true
                        } label: {
                            Label("Send Update Now", systemImage: "message.fill")
                        }
                        .disabled(!MessageComposeView.canSendText)
                    } footer: {
                        if MessageComposeView.canSendText {
                            Text("Opens Messages with a pre-filled status update for your caregivers.")
                        } else {
                            Text("This device is not able to send messages.")
                        }
                    }
                    .listRowBackground(Color.chart)

                    Section {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Automatic updates", systemImage: "bolt.badge.clock")
                                .font(.headline)
                            Text(
                                "iOS does not let apps send iMessages silently. To send updates without any taps, open the Shortcuts app and create a personal automation (for example on a schedule) that runs the Trio action 'Get Caregiver Update' and passes its result to the 'Send Message' action with your caregiver as recipient. Shortcuts automations can run and send the message without confirmation."
                            )
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        }.padding(.vertical, 5)
                    }
                    .listRowBackground(Color.chart)
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
            .sheet(isPresented: $isPresentingComposer) {
                MessageComposeView(recipients: state.parsedRecipients, messageBody: composedMessage)
                    .ignoresSafeArea()
            }
            .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
            .onAppear(perform: configureView)
            .navigationBarTitle("Caregiver Messaging")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }
    }
}
