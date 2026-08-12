import Combine
import SwiftUI
import Swinject
import UIKit

extension RemoteControlConfig {
    struct RootView: BaseView {
        let resolver: Resolver

        @StateObject var state = StateModel()

        @State private var shouldDisplayHint: Bool = false
        @State var hintDetent = PresentationDetent.large
        @State var selectedVerboseHint: AnyView?
        @State var hintLabel: String?
        @State private var decimalPlaceholder: Decimal = 0.0
        @State private var isCopied: Bool = false
        @State private var showFollowerNamePrompt: Bool = false
        @State private var newFollowerName: String = ""

        @Environment(\.colorScheme) var colorScheme
        @Environment(AppState.self) var appState

        private func followerDetailText(_ follower: PairedFollower) -> String {
            let paired = String(
                format: String(localized: "Paired %@", comment: "Follower pairing date"),
                follower.createdAt.formatted(date: .abbreviated, time: .omitted)
            )
            let push = follower.isPushRegistered
                ? String(localized: "Status pushes on")
                : String(localized: "Awaiting first connection")
            guard let lastSeen = follower.lastSeenAt else {
                return paired + " · " + push
            }
            return paired + " · " + push + " · " + String(
                format: String(localized: "Last command %@", comment: "Follower last command date"),
                lastSeen.formatted(date: .abbreviated, time: .shortened)
            )
        }

        var body: some View {
            List {
                SettingInputSection(
                    decimalValue: $decimalPlaceholder,
                    booleanValue: $state.isTrioRemoteControlEnabled,
                    shouldDisplayHint: $shouldDisplayHint,
                    selectedVerboseHint: Binding(
                        get: { selectedVerboseHint },
                        set: {
                            selectedVerboseHint = $0.map { AnyView($0) }
                            hintLabel = String(localized: "Enable Remote Command")
                        }
                    ),
                    units: state.units,
                    type: .boolean,
                    label: String(localized: "Enable Remote Control"),
                    miniHint: String(localized: "Allow Trio to receive commands from Loop Follow remotely."),
                    verboseHint: VStack(alignment: .leading, spacing: 10) {
                        Text("Default: OFF").bold()
                        Text(
                            "When Remote Control is enabled, you can send boluses, overrides, temporary targets, carbs, and other commands to Trio via push notifications."
                        )
                        Text(
                            "To ensure security, these commands are protected by a shared secret, which must be entered in the Loop Follow app."
                        )
                    },
                    headerText: String(localized: "Trio Remote Control")
                )

                Section(
                    header: Text("Shared Secret"),
                    content: {
                        TextField("Enter Shared Secret", text: $state.sharedSecret)
                            .disableAutocorrection(true)
                            .autocapitalization(.none)
                            .padding(8)
                            .background(Color(UIColor.systemGray6))
                            .cornerRadius(8)

                        Button(action: {
                            UIPasteboard.general.string = state.sharedSecret
                            isCopied = true
                        }) {
                            Label("Copy Secret", systemImage: "doc.on.doc")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                        .alert(isPresented: $isCopied) {
                            Alert(
                                title: Text("Copied"),
                                message: Text("Shared Secret copied to clipboard"),
                                dismissButton: .default(Text("OK"))
                            )
                        }

                        Button(action: {
                            state.generateNewSharedSecret()
                        }) {
                            Label("Generate Secret", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("Follower Apps"),
                    footer: Text(
                        "Pair the Trio Follower app (iOS or Android) by QR code. Each follower gets its own secret and can be revoked individually. Commands from followers are replay-protected and follow the same safety limits as this device."
                    ),
                    content: {
                        if state.followers.isEmpty {
                            Text("No followers paired yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(state.followers) { follower in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(follower.name)
                                    Text(followerDetailText(follower))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        state.revokeFollower(id: follower.id)
                                    } label: {
                                        Label("Revoke", systemImage: "trash")
                                    }
                                }
                            }
                        }

                        Button(action: {
                            newFollowerName = ""
                            showFollowerNamePrompt = true
                        }) {
                            Label("Pair New Follower", systemImage: "qrcode")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .foregroundColor(.white)
                        .disabled(!state.isTrioRemoteControlEnabled)
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("APNS Credentials"),
                    footer: Text(
                        "Followers deliver commands through Apple push notifications, so they need the push key of the Apple Developer account this Trio was built with. Enter the Team ID, Key ID and the contents of the .p8 key file once; they are stored in the keychain and shared with followers during pairing."
                    ),
                    content: {
                        TextField("Team ID (e.g. A1B2C3D4E5)", text: $state.apnsTeamId)
                            .disableAutocorrection(true)
                            .autocapitalization(.allCharacters)
                        TextField("Key ID (e.g. F6G7H8I9J0)", text: $state.apnsKeyId)
                            .disableAutocorrection(true)
                            .autocapitalization(.allCharacters)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("APNS Key (.p8 file contents)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $state.apnsKey)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 90)
                                .disableAutocorrection(true)
                                .autocapitalization(.none)
                        }
                    }
                ).listRowBackground(Color.chart)

                Section(
                    header: Text("Android Followers (FCM)"),
                    footer: Text(
                        "Only needed for Android follower devices: they receive the host's status through Firebase Cloud Messaging. Paste the service-account JSON of your Firebase project. iOS followers work without this."
                    ),
                    content: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Firebase service-account JSON")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            TextEditor(text: $state.fcmServiceAccountJSON)
                                .font(.system(.footnote, design: .monospaced))
                                .frame(minHeight: 90)
                                .disableAutocorrection(true)
                                .autocapitalization(.none)
                        }
                    }
                ).listRowBackground(Color.chart)
            }
            .listSectionSpacing(sectionSpacing)
            .alert("Pair New Follower", isPresented: $showFollowerNamePrompt) {
                TextField("Follower name (e.g. Mom's iPhone)", text: $newFollowerName)
                Button("Cancel", role: .cancel) {}
                Button("Create QR Code") {
                    state.startPairing(name: newFollowerName)
                }
            } message: {
                Text("Give this follower device a name so you can recognize and revoke it later.")
            }
            .alert(
                "Pairing Failed",
                isPresented: Binding(
                    get: { state.pairingError != nil },
                    set: { if !$0 { state.pairingError = nil } }
                )
            ) {
                Button("OK", role: .cancel) { state.pairingError = nil }
            } message: {
                Text(state.pairingError ?? "")
            }
            .sheet(
                isPresented: Binding(
                    get: { state.pairingFollower != nil && state.pairingPayload != nil },
                    set: { if !$0 { state.finishPairing() } }
                )
            ) {
                if let follower = state.pairingFollower, let payload = state.pairingPayload {
                    FollowerPairingView(follower: follower, payload: payload) {
                        state.finishPairing()
                    }
                }
            }
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
            .navigationTitle("Remote Control")
            .navigationBarTitleDisplayMode(.automatic)
            .settingsHighlightScroll()
        }
    }
}
