import SwiftUI

/// Per-follower alert configuration: which glucose conditions this follower is
/// told about, and what each one sounds like on their phone.
///
/// The host evaluates these and pushes the alert, so what is configured here
/// reaches the follower even when the follower app is not running.
struct FollowerAlertSettingsView: View {
    let followerName: String
    let units: GlucoseUnits

    @State var settings: FollowerAlertSettings
    /// Called with every edit; the caller persists and returns what was stored,
    /// which may be clamped.
    let onChange: (FollowerAlertSettings) -> FollowerAlertSettings?

    /// Whether this follower may stop insulin delivery in an emergency.
    @State var maySuspendInsulin: Bool
    let onSuspendPermissionChange: (Bool) -> Void

    /// Hidden for web viewers: a viewer cannot act on the host at all, so
    /// there is no suspend permission to grant or withdraw.
    var showsSuspendPermission: Bool = true

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    var body: some View {
        Form {
            if showsSuspendPermission {
                Section(
                    header: Text("Emergency Stop"),
                    footer: Text(
                        "Lets \(followerName) stop all insulin delivery from the follower app. Delivery stays stopped, and this phone alarms until you answer it — nothing restarts insulin on its own. Turn this off for a follower who should be able to watch but not act."
                    )
                ) {
                    Toggle("Allow Suspending Insulin", isOn: $maySuspendInsulin)
                        .onChange(of: maySuspendInsulin) { _, newValue in
                            onSuspendPermissionChange(newValue)
                        }
                }.listRowBackground(Color.chart)
            }

            Section(
                header: Text("Glucose Alerts"),
                footer: Text(
                    "Thresholds are checked on this device and pushed to \(followerName). Alerts arrive even when the follower app is closed."
                )
            ) {
                rule(
                    title: String(localized: "Urgent Low"),
                    rule: $settings.urgentLow,
                    tint: .red
                )
                rule(
                    title: String(localized: "Low"),
                    rule: $settings.low,
                    tint: .red
                )
                rule(
                    title: String(localized: "High"),
                    rule: $settings.high,
                    tint: .orange
                )
                rule(
                    title: String(localized: "Urgent High"),
                    rule: $settings.urgentHigh,
                    tint: .orange
                )
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("No Data"),
                footer: Text("Alerts when no new glucose reading has arrived for this long.")
            ) {
                Toggle(isOn: $settings.stale.isEnabled) {
                    Text("Alert on missing data")
                }

                if settings.stale.isEnabled {
                    Picker("After", selection: $settings.stale.afterMinutes) {
                        ForEach([10, 15, 20, 30, 45, 60, 90], id: \.self) { minutes in
                            Text("\(minutes) min").tag(minutes)
                        }
                    }

                    soundPicker(selection: $settings.stale.sound)
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Repeat"),
                footer: Text(
                    "How long before an alert that is still true is sent again. Set to Never to alert only once per excursion."
                )
            ) {
                Picker("Repeat while active", selection: $settings.repeatMinutes) {
                    Text("Never").tag(0)
                    ForEach([15, 30, 45, 60, 120], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
            }
            .listRowBackground(Color.chart)

            Section(
                header: Text("Privacy"),
                footer: Text(
                    "With this off the alert says only that something needs attention, with no glucose value and no severity, so nothing health-related appears on a locked screen."
                )
            ) {
                Toggle(isOn: $settings.includeGlucoseInAlertText) {
                    Text("Show glucose in the alert")
                }
            }
            .listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden)
        .background(appState.trioBackgroundColor(for: colorScheme))
        .navigationTitle(followerName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings) { _, newValue in
            // The store clamps the thresholds into a sane order; take back what
            // it actually kept so the pickers cannot drift from the truth.
            if let stored = onChange(newValue), stored != newValue {
                settings = stored
            }
        }
    }

    @ViewBuilder private func rule(
        title: String,
        rule: Binding<FollowerAlertRule>,
        tint: Color
    ) -> some View {
        Toggle(isOn: rule.isEnabled) {
            HStack {
                Circle().fill(tint).frame(width: 8, height: 8)
                Text(title)
            }
        }

        if rule.wrappedValue.isEnabled {
            HStack {
                Text("Threshold")
                Spacer()
                Text(thresholdText(rule.wrappedValue.threshold))
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { Double(truncating: rule.wrappedValue.threshold as NSNumber) },
                    set: { rule.wrappedValue.threshold = Decimal($0.rounded()) }
                ),
                in: 40 ... 400,
                step: 1
            )
            .tint(tint)

            soundPicker(selection: rule.sound)
        }
    }

    private func soundPicker(selection: Binding<FollowerAlertSound>) -> some View {
        Picker("Sound", selection: selection) {
            ForEach(FollowerAlertSound.allCases) { sound in
                Text(sound.displayName).tag(sound)
            }
        }
    }

    private func thresholdText(_ mgdl: Decimal) -> String {
        "\(FollowerAlertManager.formatGlucose(mgdl, units: units)) \(units.rawValue)"
    }
}
