import Foundation
import UserNotifications

enum NotificationCategoryIdentifier: String {
    case trioAlert = "Trio.alert"
    case followerSuspension = "Trio.followerSuspension"
}

// MARK: - FollowerSuspensionAction

/// The answers to the alarm raised when a follower stops insulin delivery.
///
/// Both are offered on the notification itself: someone woken by this should be
/// able to answer it without unlocking and finding a screen, and confirming
/// they are alright must not require agreeing to restart insulin.
enum FollowerSuspensionAction: String, CaseIterable {
    case acknowledgeAndResume = "Trio.followerSuspension.resume"
    case acknowledgeOnly = "Trio.followerSuspension.acknowledge"

    var localizedTitle: String {
        switch self {
        case .acknowledgeAndResume:
            return String(
                localized: "I'm OK — resume insulin",
                comment: "Answers the follower suspension alarm and restarts delivery"
            )
        case .acknowledgeOnly:
            return String(
                localized: "I'm OK — stay suspended",
                comment: "Answers the follower suspension alarm but leaves delivery stopped"
            )
        }
    }
}

enum NotificationResponseAction: String, CaseIterable {
    case snooze20 = "Trio.snooze20"
    case snooze1hr = "Trio.snooze1hr"
    case snooze3hr = "Trio.snooze3hr"
    case snooze6hr = "Trio.snooze6hr"

    var duration: TimeInterval {
        TimeInterval(minutes) * 60
    }

    var minutes: Int {
        switch self {
        case .snooze20:
            return 20
        case .snooze1hr:
            return 60
        case .snooze3hr:
            return 180
        case .snooze6hr:
            return 360
        }
    }

    var localizedTitle: String {
        switch self {
        case .snooze20:
            return String(localized: "20 min", comment: "Snooze glucose alerts for 20 minutes")
        case .snooze1hr:
            return String(localized: "1 hour", comment: "Snooze glucose alerts for 1 hour")
        case .snooze3hr:
            return String(localized: "3 hours", comment: "Snooze glucose alerts for 3 hours")
        case .snooze6hr:
            return String(localized: "6 hours", comment: "Snooze glucose alerts for 6 hours")
        }
    }
}

// MARK: - CaregiverNotificationAction

enum CaregiverNotificationAction {
    static let identifier = "Trio.messageCaregiver"

    static var localizedTitle: String {
        String(localized: "Text Caregiver", comment: "Notification action to text a caregiver")
    }
}

// MARK: - NotificationCategoryFactory

enum NotificationCategoryFactory {
    /// The alarm a follower's suspension raises, with both answers attached.
    static func createFollowerSuspensionCategory() -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.followerSuspension.rawValue,
            actions: FollowerSuspensionAction.allCases.map { action in
                UNNotificationAction(
                    identifier: action.rawValue,
                    title: action.localizedTitle,
                    // Resuming insulin is not something to do from a locked
                    // screen by accident; both answers open the app, which also
                    // puts the person in front of the state they just changed.
                    options: [.foreground]
                )
            },
            intentIdentifiers: [],
            options: []
        )
    }

    static func createGlucoseCategory(includeCaregiverMessageAction: Bool = false) -> UNNotificationCategory {
        var actions = NotificationResponseAction.allCases.map { action in
            UNNotificationAction(
                identifier: action.rawValue,
                title: action.localizedTitle,
                options: []
            )
        }

        if includeCaregiverMessageAction {
            // .foreground opens the app, where a pre-filled Messages sheet is presented —
            // iOS does not allow sending the message without user confirmation.
            actions.append(
                UNNotificationAction(
                    identifier: CaregiverNotificationAction.identifier,
                    title: CaregiverNotificationAction.localizedTitle,
                    options: [.foreground]
                )
            )
        }

        return UNNotificationCategory(
            identifier: NotificationCategoryIdentifier.trioAlert.rawValue,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }
}
