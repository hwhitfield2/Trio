import Foundation
import Swinject
import UserNotifications

/// A suspension of insulin delivery that a paired follower asked for.
///
/// Kept in user defaults rather than the keychain: it holds no secret, it has
/// to survive the app being killed, and the app must know on the next launch
/// that delivery is off and why.
struct FollowerSuspension: Codable, Equatable {
    let followerId: String
    let followerName: String
    let requestedAt: Date

    /// When the person holding this phone confirmed they had seen the alarm.
    var acknowledgedAt: Date?
    /// When delivery was resumed, if the acknowledgement resumed it.
    var resumedAt: Date?

    /// Still alarming: nobody on this phone has responded yet.
    var isAwaitingAcknowledgement: Bool { acknowledgedAt == nil }
}

/// Stops insulin on a follower's say-so, and keeps asking the person holding
/// this phone to confirm they are alright.
///
/// The rules this enforces are the reason it exists as its own service rather
/// than a few lines in the command dispatcher:
///
///   * **Nothing resumes delivery on its own.** Not the loop — it already
///     refuses to enact against a suspended pump — and not a timer here.
///     Insulin restarting unattended, into someone who may be in the state that
///     prompted the suspension, is the worse failure of the two.
///   * **The alarm repeats until it is answered.** A single notification can be
///     slept through, and the whole point of the feature is that someone is
///     worried about the person holding this phone.
///   * **Acknowledging and resuming are separate choices.** "I am alright" and
///     "start my insulin again" are not the same sentence, and someone woken by
///     this alarm should not have to give the second to say the first.
///
/// The corollary is that a suspension nobody answers stays in force, and hours
/// without insulin carry their own danger. Followers are shown how long it has
/// been unacknowledged precisely so they escalate by some other means — a call,
/// or going there — rather than trusting this to sort itself out.
final class FollowerSuspensionManager: Injectable {
    static let shared = FollowerSuspensionManager()

    @Injected() private var apsManager: APSManager!

    private let queue = DispatchQueue(label: "FollowerSuspensionManager.queue")
    private let notificationCenter = UNUserNotificationCenter.current()

    private static let stateKey = "followerSuspension.current"

    /// How often the alarm repeats while it goes unanswered. Short enough to
    /// wake someone, long enough not to be unusable while they deal with it.
    static let alarmInterval: TimeInterval = 2 * 60

    static let notificationIdentifier = "Trio.followerSuspensionAlarm"

    init(resolver: Resolver = TrioApp.resolver) {
        injectServices(resolver)
    }

    // MARK: - State

    /// The suspension in force, or nil when no follower has stopped delivery.
    var current: FollowerSuspension? {
        queue.sync { load() }
    }

    /// Whether a follower's suspension is still waiting for someone here to say
    /// they are alright.
    var isAwaitingAcknowledgement: Bool {
        current?.isAwaitingAcknowledgement ?? false
    }

    // MARK: - Suspending

    enum SuspendOutcome {
        case suspended
        case notPermitted
        case failed(String)
    }

    /// Stops insulin delivery at a follower's request and starts the alarm.
    ///
    /// The follower is told what actually happened by the status snapshot that
    /// follows every command, which reports the pump's own state — never by
    /// this returning, which only says the host received the message.
    func suspend(requestedBy follower: PairedFollower) async -> SuspendOutcome {
        guard follower.maySuspendInsulin else {
            return .notPermitted
        }

        // Already suspended by an earlier request: keep the original record, so
        // the elapsed time the follower sees is time without insulin, not time
        // since the last of several presses.
        if let existing = current, existing.isAwaitingAcknowledgement {
            await scheduleAlarm(for: existing)
            return .suspended
        }

        let outcome = await performSuspend()
        guard outcome.success else {
            return .failed(outcome.message)
        }

        let suspension = FollowerSuspension(
            followerId: follower.id,
            followerName: follower.name,
            requestedAt: Date()
        )
        queue.sync { save(suspension) }
        await scheduleAlarm(for: suspension)

        debug(.remoteControl, "Insulin suspended at the request of follower \(follower.name)")
        return .suspended
    }

    // MARK: - Acknowledging

    /// Records that someone here answered the alarm, and optionally starts
    /// insulin again.
    ///
    /// - Parameter resumeDelivery: whether to resume insulin now. Answering the
    ///   alarm without resuming is a legitimate outcome: the person may be
    ///   alright and still want delivery off while they sort something out.
    @discardableResult
    func acknowledge(resumeDelivery: Bool) async -> Bool {
        guard var suspension = current else { return false }

        cancelAlarm()

        var resumed = true
        if resumeDelivery {
            let outcome = await performResume()
            resumed = outcome.success
            if resumed {
                suspension.resumedAt = Date()
            }
        }

        suspension.acknowledgedAt = Date()
        queue.sync { save(suspension) }

        // Let the followers who are watching know, rather than making them wait
        // for the next reading.
        await publishToFollowers()

        debug(
            .remoteControl,
            "Follower suspension acknowledged (resume requested: \(resumeDelivery), resumed: \(resumed))"
        )
        return resumed
    }

    /// Forgets the record once delivery is running again, so a later suspension
    /// starts from a clean slate. Safe to call when there is nothing to clear.
    func clearIfResumed() {
        guard let suspension = current, suspension.acknowledgedAt != nil else { return }
        guard apsManager?.isSuspended == false else { return }
        cancelAlarm()
        queue.sync { save(nil) }
    }

    /// Drops the record for a follower being revoked, so a re-pairing does not
    /// inherit someone else's suspension.
    func clearState(followerId: String) {
        guard let suspension = current, suspension.followerId == followerId else { return }
        cancelAlarm()
        queue.sync { save(nil) }
    }

    // MARK: - Alarm

    private func scheduleAlarm(for suspension: FollowerSuspension) async {
        let content = UNMutableNotificationContent()
        content.title = String(
            localized: "Insulin suspended",
            comment: "Alarm title when a follower has suspended insulin delivery"
        )
        content.body = String(
            format: String(
                localized: "%@ stopped your insulin at %@. Confirm you are alright.",
                comment: "Alarm body naming the follower who suspended insulin and when"
            ),
            suspension.followerName,
            suspension.requestedAt.formatted(date: .omitted, time: .shortened)
        )
        content.sound = .default
        // Time-sensitive breaks through Focus, which is the case this alarm
        // exists for. Critical alerts would also override the ringer switch,
        // but they need an entitlement Apple grants per app, which this build
        // cannot assume it has.
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationCategoryIdentifier.followerSuspension.rawValue

        // Repeating rather than one-off: unanswered, this has to keep asking.
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.alarmInterval, repeats: true)
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: trigger
        )

        // The repeating trigger only fires after the first interval, so the
        // first alarm is delivered immediately alongside it.
        let immediate = UNNotificationRequest(
            identifier: Self.notificationIdentifier + ".now",
            content: content,
            trigger: nil
        )

        do {
            try await notificationCenter.add(immediate)
            try await notificationCenter.add(request)
        } catch {
            warning(.remoteControl, "Could not schedule the follower suspension alarm", error: error)
        }
    }

    private func cancelAlarm() {
        let identifiers = [Self.notificationIdentifier, Self.notificationIdentifier + ".now"]
        notificationCenter.removePendingNotificationRequests(withIdentifiers: identifiers)
        notificationCenter.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    // MARK: - Pump

    private func performSuspend() async -> (success: Bool, message: String) {
        guard let apsManager = apsManager else {
            return (false, String(localized: "No pump configured."))
        }
        return await withCheckedContinuation { continuation in
            Task {
                await apsManager.suspendPump { success, message in
                    continuation.resume(returning: (success, message))
                }
            }
        }
    }

    private func performResume() async -> (success: Bool, message: String) {
        guard let apsManager = apsManager else {
            return (false, String(localized: "No pump configured."))
        }
        return await withCheckedContinuation { continuation in
            Task {
                await apsManager.resumePump { success, message in
                    continuation.resume(returning: (success, message))
                }
            }
        }
    }

    private func publishToFollowers() async {
        guard let publisher = TrioApp.resolver.resolve(FollowerStatusPublisher.self) else { return }
        // Per follower rather than publishToAllFollowers(), which is throttled
        // to one push a minute: a follower waiting to hear that the person they
        // were worried about has answered should not wait out a throttle.
        for follower in FollowerPairingManager.shared.followers where follower.isPushRegistered {
            await publisher.publish(toFollowerId: follower.id)
        }
    }

    // MARK: - Storage

    private func load() -> FollowerSuspension? {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let decoded = try? JSONDecoder().decode(FollowerSuspension.self, from: data)
        else { return nil }
        return decoded
    }

    private func save(_ suspension: FollowerSuspension?) {
        guard let suspension else {
            UserDefaults.standard.removeObject(forKey: Self.stateKey)
            return
        }
        guard let data = try? JSONEncoder().encode(suspension) else { return }
        UserDefaults.standard.set(data, forKey: Self.stateKey)
    }
}
