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
            // A follower moved here by a device-setup transfer that could never
            // register a push address cannot be told where this device is — the
            // only way forward for it is a fresh pairing QR code.
            if follower.needsHostUpdate == true, !follower.isPushRegistered {
                return String(
                    localized: "Moved from the old device, but unreachable — re-pair this follower with a new QR code.",
                    comment: "Follower migrated by device setup that cannot be told the new host address"
                )
            }

            let paired = String(
                format: String(localized: "Paired %@", comment: "Follower pairing date"),
                follower.createdAt.formatted(date: .abbreviated, time: .omitted)
            )
            var push = follower.isPushRegistered
                ? String(localized: "Status pushes on")
                : String(localized: "Awaiting first connection")
            if follower.needsHostUpdate == true {
                push = String(
                    localized: "Moving to this device…",
                    comment: "Follower migrated by device setup, not yet told the new host address"
                )
            }
            guard let lastSeen = follower.lastSeenAt else {
                return paired + " · " + push
            }
            return paired + " · " + push + " · " + String(
                format: String(localized: "Last command %@", comment: "Follower last command date"),
                lastSeen.formatted(date: .abbreviated, time: .shortened)
            )
        }

        /// The follower's own build, and whether it is behind the current
        /// release. A follower that has never reported one is shown as unknown
        /// rather than assumed current.
        private func followerVersionText(_ follower: PairedFollower) -> String {
            guard let version = follower.appVersion, !version.isEmpty else {
                return String(
                    localized: "Version unknown — it reports one the next time it connects",
                    comment: "Follower with no reported app version"
                )
            }
            let installed = String(
                format: String(localized: "Version %@", comment: "Follower app version"),
                version
            )
            guard follower.isOutdated(comparedTo: state.latestFollowerVersion) else { return installed }
            return installed + " · " + String(localized: "Update available", comment: "Follower is behind the latest release")
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
                        "Pair the Trio Follower app (iOS or Android) by QR code. Each follower gets its own secret and can be revoked individually. Commands from followers are replay-protected and follow the same safety limits as this device. Tap a follower to choose which glucose alerts it receives and what they sound like."
                    ),
                    content: {
                        if let suspension = state.suspension, suspension.isAwaitingAcknowledgement {
                            VStack(alignment: .leading, spacing: 8) {
                                Label {
                                    Text("Insulin suspended by \(suspension.followerName)")
                                        .fontWeight(.bold)
                                } icon: {
                                    Image(systemName: "exclamationmark.octagon.fill")
                                        .foregroundColor(.red)
                                }

                                Text(
                                    "Stopped at \(suspension.requestedAt.formatted(date: .omitted, time: .shortened)). Delivery stays stopped until you answer, and this phone keeps alarming until then."
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)

                                Button {
                                    state.acknowledgeSuspension(resumeDelivery: true)
                                } label: {
                                    Label("I'm OK — resume insulin", systemImage: "play.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .foregroundColor(.white)

                                Button {
                                    state.acknowledgeSuspension(resumeDelivery: false)
                                } label: {
                                    Label("I'm OK — stay suspended", systemImage: "pause.circle")
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        } else if let suspension = state.suspension {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Insulin suspended by \(suspension.followerName)")
                                Text(
                                    suspension.resumedAt == nil
                                        ? String(localized: "Acknowledged — delivery is still stopped.")
                                        : String(localized: "Acknowledged — delivery resumed.")
                                )
                                .font(.caption)
                                .foregroundColor(.secondary)

                                if suspension.resumedAt == nil {
                                    Button {
                                        state.acknowledgeSuspension(resumeDelivery: true)
                                    } label: {
                                        Label("Resume insulin", systemImage: "play.circle")
                                    }
                                }
                            }
                        }

                        if state.followers.isEmpty {
                            Text("No followers paired yet.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(state.followers) { follower in
                                NavigationLink {
                                    FollowerAlertSettingsView(
                                        followerName: follower.name,
                                        units: state.units,
                                        settings: state.alertSettings(forFollowerId: follower.id),
                                        onChange: { state.updateAlertSettings(followerId: follower.id, $0) },
                                        maySuspendInsulin: follower.maySuspendInsulin,
                                        onSuspendPermissionChange: {
                                            state.setMaySuspendInsulin(followerId: follower.id, $0)
                                        }
                                    )
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(follower.name)
                                        Text(followerDetailText(follower))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        HStack(spacing: 4) {
                                            if follower.isOutdated(comparedTo: state.latestFollowerVersion) {
                                                Image(systemName: "arrow.up.circle.fill")
                                                    .foregroundColor(.orange)
                                                    .font(.caption)
                                            }
                                            Text(followerVersionText(follower))
                                                .font(.caption)
                                                .foregroundColor(
                                                    follower.isOutdated(comparedTo: state.latestFollowerVersion)
                                                        ? .orange
                                                        : .secondary
                                                )
                                        }
                                    }
                                }
                                .swipeActions {
                                    Button(role: .destructive) {
                                        state.revokeFollower(id: follower.id)
                                    } label: {
                                        Label("Revoke", systemImage: "trash")
                                    }

                                    if follower.isOutdated(comparedTo: state.latestFollowerVersion),
                                       follower.isPushRegistered
                                    {
                                        Button {
                                            state.nudgeFollower(id: follower.id)
                                        } label: {
                                            Label("Notify", systemImage: "bell.badge")
                                        }
                                        .tint(.orange)
                                    }
                                }
                            }
                        }

                        if !state.followers.isEmpty {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Latest follower release")
                                    Text(state.latestFollowerVersion ?? String(
                                        localized: "Not checked yet",
                                        comment: "The latest follower release could not be looked up"
                                    ))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                }
                                Spacer()
                                if state.isCheckingFollowerVersion {
                                    ProgressView()
                                } else {
                                    Button {
                                        state.refreshLatestFollowerVersion(force: true)
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }

                            if !state.outdatedFollowers.isEmpty {
                                Button {
                                    state.nudgeOutdatedFollowers()
                                } label: {
                                    Label(
                                        String(
                                            format: String(
                                                localized: "Notify %lld follower(s) to update",
                                                comment: "Button that sends an update notice to every outdated follower"
                                            ),
                                            state.outdatedFollowers.count
                                        ),
                                        systemImage: "bell.badge"
                                    )
                                }
                                .disabled(!state.isTrioRemoteControlEnabled)
                            }

                            if let nudgeResult = state.nudgeResult {
                                Text(nudgeResult)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
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
