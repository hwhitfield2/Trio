import Combine
import Foundation
import Swinject
import UserNotifications

/// Non-dosing watchdog for CGM silence (docs/ML_DOSING_REPLACEMENT_PLAN.md §2.1).
///
/// The loop is strictly event-driven — no new CGM value, no cycle — so silence
/// must surface to the user rather than to software: any running temp basal
/// expires to profile basal on its own, and this watchdog raises escalating
/// local notifications at 10/20/30 minutes without a newly stored value. It
/// alerts only and never doses; the CGM's own urgent-low alarms remain fully
/// independent of it.
///
/// Notifications are (re)scheduled in advance on every stored value, so they
/// fire even if the app is suspended when the sensor goes quiet.
protocol CGMSilenceWatchdog {}

final class BaseCGMSilenceWatchdog: CGMSilenceWatchdog, Injectable {
    @Injected() private var glucoseStorage: GlucoseStorage!

    private let center = UNUserNotificationCenter.current()
    private var lifetime = Lifetime()

    private static let escalationMinutes = [10, 20, 30]

    private static func identifier(for minutes: Int) -> String {
        "trio.cgmSilenceWatchdog.\(minutes)"
    }

    init(resolver: Resolver) {
        injectServices(resolver)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.rearm() }
            .store(in: &lifetime)
        rearm()
    }

    /// Cancels pending silence alerts and schedules a fresh escalation ladder
    /// counted from now (a value was just stored, or the app just started).
    private func rearm() {
        center.removePendingNotificationRequests(
            withIdentifiers: Self.escalationMinutes.map(Self.identifier(for:))
        )
        for minutes in Self.escalationMinutes {
            let content = UNMutableNotificationContent()
            content.title = String(localized: "No CGM data", comment: "CGM silence watchdog notification title")
            content.body = String(
                localized: "No new CGM value for \(minutes) minutes. The loop is idle; any temp basal will expire to your profile basal.",
                comment: "CGM silence watchdog notification body"
            )
            content.sound = .default
            content.interruptionLevel = minutes >= 30 ? .timeSensitive : .active
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: Double(minutes) * 60,
                repeats: false
            )
            center.add(UNNotificationRequest(
                identifier: Self.identifier(for: minutes),
                content: content,
                trigger: trigger
            ))
        }
    }
}
