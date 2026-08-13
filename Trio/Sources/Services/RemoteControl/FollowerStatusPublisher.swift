import CoreData
import Foundation
import Swinject

/// Snapshot of the host's current state, encrypted per follower and delivered
/// by push. This is the follower app's only data source — no Nightscout or
/// other third-party service is involved.
struct FollowerStatusSnapshot: Encodable {
    struct Reading: Encodable {
        let sgv: Int
        /// Unix seconds.
        let date: TimeInterval
        let direction: String?
    }

    struct ActiveTempTarget: Encodable {
        /// mg/dL
        let target: Double
        let name: String
        /// Unix seconds.
        let startedAt: TimeInterval
        /// Minutes.
        let duration: Double

        enum CodingKeys: String, CodingKey {
            case target
            case name
            case startedAt = "started_at"
            case duration
        }
    }

    struct ActiveOverride: Encodable {
        let name: String
        let startedAt: TimeInterval
        let duration: Double

        enum CodingKeys: String, CodingKey {
            case name
            case startedAt = "started_at"
            case duration
        }
    }

    let type: String
    /// Unix seconds when the snapshot was created; followers reject stale or
    /// out-of-order snapshots.
    let timestamp: TimeInterval
    let units: String
    /// Newest first. Trimmed from the oldest end when the encrypted payload
    /// would not fit in an APNS background notification.
    var readings: [Reading]
    let iob: Double?
    let cob: Double?
    /// Unix seconds of the last enacted loop determination.
    let lastLoop: TimeInterval?
    let eventualBG: Double?
    let tempTarget: ActiveTempTarget?
    let override: ActiveOverride?
    let maxBolus: Double
    let maxCarbs: Double
    /// The low and high thresholds this follower is alerted on, in mg/dL. Two
    /// numbers, so the follower can colour glucose the way the host does without
    /// the whole alert profile having to fit the push budget. Substituted per
    /// follower by `withThresholds(from:)`.
    var low: Double
    var high: Double

    /// Whether insulin delivery is stopped right now, straight from the pump's
    /// own state. A follower only ever learns that its emergency suspension
    /// took effect from this — never from the push having been accepted.
    ///
    /// Defaulted, so a snapshot built without mentioning suspension reads as
    /// delivering — the safe way round, and the way every caller that predates
    /// the emergency stop already means it.
    var suspended: Bool = false
    /// The follower that asked for the suspension, when one did.
    var suspendedBy: String?
    /// Unix seconds when that request was made.
    var suspendedAt: TimeInterval?
    /// Whether someone holding the host phone has answered the alarm.
    var suspendAcknowledged: Bool = false

    enum CodingKeys: String, CodingKey {
        case type
        case timestamp
        case units
        case readings
        case iob
        case cob
        case lastLoop = "last_loop"
        case eventualBG = "eventual_bg"
        case tempTarget = "temp_target"
        case override
        case maxBolus = "max_bolus"
        case maxCarbs = "max_carbs"
        case low
        case high
        case suspended
        case suspendedBy = "suspended_by"
        case suspendedAt = "suspended_at"
        case suspendAcknowledged = "suspend_acknowledged"
    }
}

protocol FollowerStatusPublisher {
    /// Publishes the current status to every push-registered follower.
    func publishToAllFollowers()
    /// Publishes to one follower (used for status_request and right after
    /// push registration).
    func publish(toFollowerId followerId: String) async
}

/// Observes glucose and loop updates on the host and pushes encrypted status
/// snapshots to all paired followers, so the follower app gets its data from
/// the host device itself.
final class BaseFollowerStatusPublisher: FollowerStatusPublisher, Injectable {
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var apsManager: APSManager!

    private let context = CoreDataStack.shared.newTaskContext()
    private let throttleQueue = DispatchQueue(label: "BaseFollowerStatusPublisher.throttle")
    private var lastPublishedAt: Date = .distantPast

    /// Publishing on every observer event would send duplicate pushes when a
    /// glucose update is followed by the loop's determination moments later;
    /// one snapshot per minute is plenty for a 5-minute CGM cycle.
    private let minimumPublishInterval: TimeInterval = 60

    init(resolver: Resolver) {
        injectServices(resolver)
        broadcaster.register(GlucoseObserver.self, observer: self)
        broadcaster.register(DeterminationObserver.self, observer: self)
    }

    func publishToAllFollowers() {
        // Either registration is reason enough to build a snapshot: they are
        // separate opt-ins, and a follower can hold one without the other.
        let followers = FollowerPairingManager.shared.followers
            .filter { $0.isPushRegistered || $0.isLiveActivityRegistered }
        guard !followers.isEmpty else { return }

        let shouldPublish: Bool = throttleQueue.sync {
            guard Date().timeIntervalSince(lastPublishedAt) >= minimumPublishInterval else { return false }
            lastPublishedAt = Date()
            return true
        }
        guard shouldPublish else { return }

        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            await self.publish(to: followers)
        }
    }

    func publish(toFollowerId followerId: String) async {
        guard let follower = FollowerPairingManager.shared.follower(withId: followerId),
              follower.isPushRegistered || follower.isLiveActivityRegistered
        else { return }
        await publish(to: [follower])
    }

    private func publish(to followers: [PairedFollower]) async {
        do {
            let snapshot = try await buildSnapshot()
            let encoder = JSONEncoder()

            for follower in followers {
                guard let messenger = SecureMessenger(sharedSecret: follower.secret) else { continue }
                // Each follower sees its own thresholds, so the encoding is
                // per-follower rather than shared.
                let personalised = snapshot.withThresholds(from: follower.alertSettings)
                if follower.isPushRegistered {
                    let snapshotData = try encodeWithinPushLimit(personalised, using: encoder)
                    do {
                        let encrypted = try messenger.encrypt(data: snapshotData)
                        try await FollowerPushSender.shared.sendStatus(encryptedStatus: encrypted, to: follower)
                        debug(.remoteControl, "Status snapshot pushed to follower \(follower.name)")
                    } catch {
                        debug(
                            .remoteControl,
                            "Failed to push status to follower \(follower.name): \(error)"
                        )
                    }
                }

                await publishLiveActivity(personalised, to: follower)
            }
        } catch {
            debug(.remoteControl, "Failed to build follower status snapshot: \(error)")
        }
    }

    /// Pushes the same reading straight to the follower's Live Activity.
    ///
    /// Separate from the status push on purpose: the status push only reaches
    /// the Lock Screen if the system decides to wake the follower app, which it
    /// often does not. This one is drawn by ActivityKit whether the app runs or
    /// not, so it is the only update that survives the app being suspended or
    /// swiped away. A follower that has not opted in has no token and is
    /// skipped.
    private func publishLiveActivity(_ snapshot: FollowerStatusSnapshot, to follower: PairedFollower) async {
        guard follower.isLiveActivityRegistered,
              let state = FollowerLiveActivityState.from(snapshot: snapshot)
        else { return }

        do {
            try await FollowerPushSender.shared.sendLiveActivity(state: state, to: follower)
            debug(.remoteControl, "Live Activity pushed to follower \(follower.name)")
        } catch {
            debug(.remoteControl, "Failed to push Live Activity to follower \(follower.name): \(error)")
        }
    }

    // MARK: - Push size budget

    /// APNS rejects a background notification larger than 4 KB.
    private static let apnsPayloadLimit = 4096
    /// The `aps` dictionary, `follower_id` and the JSON scaffolding wrapped
    /// around `encrypted_status`.
    private static let apnsEnvelopeOverhead = 128

    /// Encodes the snapshot, dropping the oldest readings until the payload it
    /// will become fits an APNS background push.
    ///
    /// The snapshot is encrypted and base64-encoded before it is sent, which
    /// inflates it by a third, so the plaintext budget is much smaller than the
    /// 4 KB limit suggests: a full 6 hours of readings encodes to well over
    /// 6 KB of payload. APNS answers those with 413 PayloadTooLarge, which the
    /// follower only ever sees as a status that never arrives — so trim here
    /// rather than let the push fail.
    private func encodeWithinPushLimit(
        _ snapshot: FollowerStatusSnapshot,
        using encoder: JSONEncoder
    ) throws -> Data {
        var snapshot = snapshot
        var data = try encoder.encode(snapshot)
        while projectedPayloadSize(plaintextBytes: data.count) > Self.apnsPayloadLimit, !snapshot.readings.isEmpty {
            // Readings are newest first, so the last one is the oldest.
            snapshot.readings.removeLast()
            data = try encoder.encode(snapshot)
        }
        return data
    }

    private func projectedPayloadSize(plaintextBytes: Int) -> Int {
        let encrypted = 12 + plaintextBytes + 16 // nonce || ciphertext || GCM tag
        let base64 = (encrypted + 2) / 3 * 4
        return base64 + Self.apnsEnvelopeOverhead
    }

    // MARK: - Snapshot assembly

    private func buildSnapshot() async throws -> FollowerStatusSnapshot {
        let readings = try await fetchReadings()
        let determination = try await fetchDetermination()
        let tempTarget = try await fetchActiveTempTarget()
        let override = try await fetchActiveOverride()

        let iob = iobService.currentIOB.map { Double(truncating: $0 as NSNumber) }
        let settings = settingsManager.settings

        // The pump's own state, not a record of what was asked for: a
        // suspension that failed to reach the pump must never read as success
        // on a follower's screen.
        let suspended = apsManager.isSuspended
        let suspension = suspended ? FollowerSuspensionManager.shared.current : nil

        return FollowerStatusSnapshot(
            type: "status",
            timestamp: Date().timeIntervalSince1970.rounded(),
            units: settings.units.rawValue,
            readings: readings,
            iob: iob,
            cob: determination?.cob,
            lastLoop: determination?.date?.timeIntervalSince1970.rounded(),
            eventualBG: determination?.eventualBG,
            tempTarget: tempTarget,
            override: override,
            maxBolus: Double(truncating: settingsManager.pumpSettings.maxBolus as NSNumber),
            maxCarbs: Double(truncating: settings.maxCarbs as NSNumber),
            low: Double(truncating: FollowerAlertSettings.default.low.threshold as NSNumber),
            high: Double(truncating: FollowerAlertSettings.default.high.threshold as NSNumber),
            suspended: suspended,
            suspendedBy: suspension?.followerName,
            suspendedAt: suspension?.requestedAt.timeIntervalSince1970.rounded(),
            suspendAcknowledged: suspension?.acknowledgedAt != nil
        )
    }

    private func fetchReadings() async throws -> [FollowerStatusSnapshot.Reading] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForSixHoursAgo,
            key: "date",
            ascending: false,
            // ~4 hours at a 5-minute CGM cadence. Six hours (72) does not fit
            // an APNS background push once encrypted and base64-encoded; see
            // encodeWithinPushLimit, which enforces the real budget.
            fetchLimit: 48
        )

        return await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else { return [] }
            return glucoseResults.map {
                FollowerStatusSnapshot.Reading(
                    sgv: Int($0.glucose),
                    // Whole seconds: sub-second precision costs ~7 bytes per
                    // reading in the payload and means nothing for a CGM.
                    // Followers parse this as a number, so integers are
                    // wire-compatible with already-released builds.
                    date: ($0.date ?? Date()).timeIntervalSince1970.rounded(),
                    direction: $0.directionEnum?.rawValue
                )
            }
        }
    }

    private struct DeterminationSummary {
        let cob: Double?
        let eventualBG: Double?
        let date: Date?
    }

    private func fetchDetermination() async throws -> DeterminationSummary? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate.predicateFor30MinAgoForDetermination,
            key: "deliverAt",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["cob", "deliverAt", "eventualBG"]
        )

        return await context.perform {
            guard let rows = results as? [[String: Any]], let row = rows.first else { return nil }
            return DeterminationSummary(
                cob: (row["cob"] as? Int).map(Double.init),
                eventualBG: (row["eventualBG"] as? NSDecimalNumber).map { Double(truncating: $0) },
                date: row["deliverAt"] as? Date
            )
        }
    }

    private func fetchActiveTempTarget() async throws -> FollowerStatusSnapshot.ActiveTempTarget? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TempTargetStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForOneDayAgo,
            key: "date",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["enabled", "name", "target", "date", "duration"]
        )

        return await context.perform {
            guard let rows = results as? [[String: Any]], let row = rows.first,
                  row["enabled"] as? Bool == true
            else { return nil }
            let startedAt = (row["date"] as? Date) ?? Date()
            let duration = (row["duration"] as? NSDecimalNumber).map { Double(truncating: $0) } ?? 0
            guard startedAt.addingTimeInterval(duration * 60) > Date() else { return nil }
            return FollowerStatusSnapshot.ActiveTempTarget(
                target: (row["target"] as? NSDecimalNumber).map { Double(truncating: $0) } ?? 0,
                name: row["name"] as? String ?? "Temp Target",
                startedAt: startedAt.timeIntervalSince1970,
                duration: duration
            )
        }
    }

    private func fetchActiveOverride() async throws -> FollowerStatusSnapshot.ActiveOverride? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OverrideStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForOneDayAgo,
            key: "date",
            ascending: false,
            fetchLimit: 1,
            propertiesToFetch: ["enabled", "name", "date", "duration"]
        )

        return await context.perform {
            guard let rows = results as? [[String: Any]], let row = rows.first,
                  row["enabled"] as? Bool == true
            else { return nil }
            let startedAt = (row["date"] as? Date) ?? Date()
            return FollowerStatusSnapshot.ActiveOverride(
                name: row["name"] as? String ?? "Override",
                startedAt: startedAt.timeIntervalSince1970,
                duration: (row["duration"] as? NSDecimalNumber).map { Double(truncating: $0) } ?? 0
            )
        }
    }
}

extension FollowerStatusSnapshot {
    /// The same snapshot with one follower's alert thresholds substituted in.
    func withThresholds(from settings: FollowerAlertSettings) -> FollowerStatusSnapshot {
        var copy = self
        copy.low = Double(truncating: settings.low.threshold as NSNumber)
        copy.high = Double(truncating: settings.high.threshold as NSNumber)
        return copy
    }
}

extension BaseFollowerStatusPublisher: GlucoseObserver {
    func glucoseDidUpdate(_: [BloodGlucose]) {
        publishToAllFollowers()
        evaluateAlerts()
    }
}

extension BaseFollowerStatusPublisher: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        publishToAllFollowers()
    }
}

extension BaseFollowerStatusPublisher {
    /// Alerting is deliberately not throttled with the status pushes: a status
    /// snapshot that is one minute stale is fine, an urgent low that is one
    /// minute late is not.
    func evaluateAlerts() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self = self else { return }
            do {
                let readings = try await self.fetchReadings()
                let newest = readings.first
                await FollowerAlertManager.shared.evaluate(
                    glucose: newest.map { Decimal($0.sgv) },
                    readingDate: newest.map { Date(timeIntervalSince1970: $0.date) },
                    units: self.settingsManager.settings.units
                )
            } catch {
                debug(.remoteControl, "Failed to evaluate follower alerts: \(error)")
            }
        }
    }
}
