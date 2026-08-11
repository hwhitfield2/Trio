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
    /// Newest first, up to 6 hours.
    let readings: [Reading]
    let iob: Double?
    let cob: Double?
    /// Unix seconds of the last enacted loop determination.
    let lastLoop: TimeInterval?
    let eventualBG: Double?
    let tempTarget: ActiveTempTarget?
    let override: ActiveOverride?
    let maxBolus: Double
    let maxCarbs: Double

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
        let followers = FollowerPairingManager.shared.followers.filter(\.isPushRegistered)
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
              follower.isPushRegistered
        else { return }
        await publish(to: [follower])
    }

    private func publish(to followers: [PairedFollower]) async {
        do {
            let snapshot = try await buildSnapshot()
            let encoder = JSONEncoder()
            let snapshotData = try encoder.encode(snapshot)

            for follower in followers {
                guard let messenger = SecureMessenger(sharedSecret: follower.secret) else { continue }
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
        } catch {
            debug(.remoteControl, "Failed to build follower status snapshot: \(error)")
        }
    }

    // MARK: - Snapshot assembly

    private func buildSnapshot() async throws -> FollowerStatusSnapshot {
        let readings = try await fetchReadings()
        let determination = try await fetchDetermination()
        let tempTarget = try await fetchActiveTempTarget()
        let override = try await fetchActiveOverride()

        let iob = iobService.currentIOB.map { Double(truncating: $0 as NSNumber) }
        let settings = settingsManager.settings

        return FollowerStatusSnapshot(
            type: "status",
            timestamp: Date().timeIntervalSince1970,
            units: settings.units.rawValue,
            readings: readings,
            iob: iob,
            cob: determination?.cob,
            lastLoop: determination?.date?.timeIntervalSince1970,
            eventualBG: determination?.eventualBG,
            tempTarget: tempTarget,
            override: override,
            maxBolus: Double(truncating: settingsManager.pumpSettings.maxBolus as NSNumber),
            maxCarbs: Double(truncating: settings.maxCarbs as NSNumber)
        )
    }

    private func fetchReadings() async throws -> [FollowerStatusSnapshot.Reading] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForSixHoursAgo,
            key: "date",
            ascending: false,
            fetchLimit: 72
        )

        return await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else { return [] }
            return glucoseResults.map {
                FollowerStatusSnapshot.Reading(
                    sgv: Int($0.glucose),
                    date: ($0.date ?? Date()).timeIntervalSince1970,
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

extension BaseFollowerStatusPublisher: GlucoseObserver {
    func glucoseDidUpdate(_: [BloodGlucose]) {
        publishToAllFollowers()
    }
}

extension BaseFollowerStatusPublisher: DeterminationObserver {
    func determinationDidUpdate(_: Determination) {
        publishToAllFollowers()
    }
}
