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

    /// A bolus the pump delivered, for the follower's chart.
    ///
    /// Keys are short because a snapshot has an APNS payload to fit inside and
    /// treatments compete with glucose readings for it — see
    /// `encodedWithinPushLimit`.
    struct Bolus: Encodable {
        /// Units.
        let a: Double
        /// Unix seconds.
        let t: TimeInterval
        /// True for a bolus the loop gave itself (an SMB), and absent for one a
        /// person asked for: a nil Optional encodes to no key at all, which is
        /// the cheapest way to say "no".
        let s: Bool?
    }

    /// A carb entry someone logged on the host.
    struct CarbEntry: Encodable {
        /// Grams.
        let g: Double
        /// Unix seconds.
        let t: TimeInterval
    }

    /// The glucose ranges the host colours by, so a follower's chart paints the
    /// same reading the same colour the host does. Distinct from `low`/`high`
    /// below: those are the thresholds this follower is *alerted* on, which a
    /// follower sets for itself and which say nothing about how the host
    /// displays glucose.
    struct GlucoseRanges: Encodable {
        /// The host's display low and high, in mg/dL (its `low`/`high`
        /// settings, not the alert profile).
        let low: Double
        let high: Double
        /// The glucose target in force right now, in mg/dL. The dynamic colour
        /// scheme shades towards green at this value.
        let target: Double
        /// `GlucoseColorScheme`'s raw value: "staticColor" or "dynamicColor".
        let scheme: String
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

    /// How the host colours glucose. Optional: hosts that predate this send no
    /// ranges, and a follower talking to one falls back to its own defaults.
    var ranges: GlucoseRanges?

    /// What was delivered and eaten over the same window as `readings`, newest
    /// first. A follower watching glucose climb needs to know whether anyone
    /// has already answered it.
    var boluses: [Bolus] = []
    var carbs: [CarbEntry] = []

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

    /// AI food search credentials, present while the host has the feature
    /// configured. Fresher than the pairing-time copy, so the follower prefers
    /// this — the same precedence rule as the limits above. Costs ~150 bytes
    /// of the push budget, which the trimming below treats like any other
    /// fixed field.
    var ai: FollowerAIConfig? = nil

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
        case ranges
        case boluses
        case carbs
        case suspended
        case suspendedBy = "suspended_by"
        case suspendedAt = "suspended_at"
        case suspendAcknowledged = "suspend_acknowledged"
        case ai
    }
}

/// One slice of a history backfill.
///
/// A status snapshot carries only the few hours that fit an APNS push, so a
/// follower's 12, 24 and 48 hour charts can otherwise show nothing but the
/// stretch that phone happened to be awake for — and re-pairing, which clears
/// its history, empties them outright. On request the host sends the rest as a
/// short run of these.
///
/// Readings only. Everything else in a snapshot — IOB, treatments, the pump's
/// state — describes *now*, and re-sending a stale copy of it two days late is
/// worse than sending none.
///
/// Deliberately carried in the same `encrypted_status` push field: a follower
/// that predates the backfill reads `type`, finds it is not `status`, and
/// drops the message.
struct FollowerHistorySlice: Encodable {
    let type = "history"
    /// Which slice this is, from 1, and how many the host is sending.
    let seq: Int
    let of: Int
    /// Newest first, like every other list of readings on the wire.
    let readings: [FollowerStatusSnapshot.Reading]

    enum CodingKeys: String, CodingKey {
        case type
        case seq
        case of
        case readings
    }
}

// MARK: - Push size budget

extension FollowerStatusSnapshot {
    /// APNS rejects a background notification larger than 4 KB.
    static let apnsPayloadLimit = 4096
    /// The `aps` dictionary, `follower_id` and the JSON scaffolding wrapped
    /// around `encrypted_status`.
    static let apnsEnvelopeOverhead = 128

    /// Readings kept before treatments start giving way instead. Two hours of
    /// glucose is the least that still reads as a trend.
    static let minimumReadings = 24

    /// Encodes the snapshot, dropping what it can spare until the payload it
    /// will become fits an APNS background push.
    ///
    /// The snapshot is encrypted and base64-encoded before it is sent, which
    /// inflates it by a third, so the plaintext budget is much smaller than the
    /// 4 KB limit suggests: a full 6 hours of readings encodes to well over
    /// 6 KB of payload. APNS answers those with 413 PayloadTooLarge, which the
    /// follower only ever sees as a status that never arrives — so trim here
    /// rather than let the push fail.
    ///
    /// What gives way, in order: treatments the chart could not draw anyway,
    /// then the oldest readings, then treatments, then whatever is left. The
    /// order is the point — a bolus is only meaningful against the glucose it
    /// was given for, and glucose without the bolus is a follower watching a
    /// number climb with no idea whether anyone has answered it.
    func encodedWithinPushLimit(using encoder: JSONEncoder) throws -> Data {
        var snapshot = self

        // Everything is newest first, so the last element of each is the oldest.
        func dropTreatmentsOffTheChart() {
            guard let oldestReading = snapshot.readings.last?.date else {
                snapshot.boluses = []
                snapshot.carbs = []
                return
            }
            snapshot.boluses.removeAll { $0.t < oldestReading }
            snapshot.carbs.removeAll { $0.t < oldestReading }
        }

        func dropOldestTreatment() {
            switch (snapshot.boluses.last?.t, snapshot.carbs.last?.t) {
            case (.some(let bolus), .some(let carb)):
                if bolus <= carb {
                    snapshot.boluses.removeLast()
                } else {
                    snapshot.carbs.removeLast()
                }
            case (.some, .none):
                snapshot.boluses.removeLast()
            case (.none, .some):
                snapshot.carbs.removeLast()
            case (.none, .none):
                break
            }
        }

        dropTreatmentsOffTheChart()
        var data = try encoder.encode(snapshot)

        while Self.projectedPayloadSize(plaintextBytes: data.count) > Self.apnsPayloadLimit {
            if snapshot.readings.count > Self.minimumReadings {
                snapshot.readings.removeLast()
                dropTreatmentsOffTheChart()
            } else if !snapshot.boluses.isEmpty || !snapshot.carbs.isEmpty {
                dropOldestTreatment()
            } else if !snapshot.readings.isEmpty {
                snapshot.readings.removeLast()
            } else {
                break
            }
            data = try encoder.encode(snapshot)
        }
        return data
    }

    static func projectedPayloadSize(plaintextBytes: Int) -> Int {
        let encrypted = 12 + plaintextBytes + 16 // nonce || ciphertext || GCM tag
        let base64 = (encrypted + 2) / 3 * 4
        return base64 + apnsEnvelopeOverhead
    }
}

protocol FollowerStatusPublisher {
    /// Publishes the current status to every push-registered follower.
    func publishToAllFollowers()
    /// Publishes to one follower (used for status_request and right after
    /// push registration).
    func publish(toFollowerId followerId: String) async
    /// Sends one follower the older readings behind its chart's longer spans
    /// (used for history_request).
    func publishHistory(toFollowerId followerId: String, hours: Int) async
}

/// Observes glucose and loop updates on the host and pushes encrypted status
/// snapshots to all paired followers, so the follower app gets its data from
/// the host device itself.
final class BaseFollowerStatusPublisher: FollowerStatusPublisher, Injectable {
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var iobService: IOBService!
    @Injected() private var apsManager: APSManager!
    @Injected() private var fileStorage: FileStorage!

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

    // MARK: - History backfill

    /// The furthest back a backfill will reach — the longest span the
    /// follower's chart offers.
    static let maximumHistoryHours = 48

    /// One reading per quarter hour. The chart is a few hundred points wide,
    /// so five-minute resolution across two days is detail nobody can see and
    /// three times the pushes to send it. The recent hours keep their full
    /// resolution regardless: the follower already has them from ordinary
    /// status pushes, and merging is by timestamp, so the coarse copy of a
    /// reading it already holds costs nothing.
    static let historyResolution: TimeInterval = 15 * 60

    /// A backfill is answered with at most this many pushes, however long a
    /// window was asked for. A bound on what one request can cost the host.
    static let maximumHistorySlices = 6

    func publishHistory(toFollowerId followerId: String, hours: Int) async {
        guard let follower = FollowerPairingManager.shared.follower(withId: followerId),
              follower.isPushRegistered,
              let messenger = SecureMessenger(sharedSecret: follower.secret)
        else { return }

        let window = min(max(hours, 1), Self.maximumHistoryHours)
        do {
            let readings = try await fetchHistoryReadings(hours: window)
            guard !readings.isEmpty else { return }

            let encoder = JSONEncoder()
            let slices = try Self.slicedForPush(readings, using: encoder)
            guard !slices.isEmpty else { return }

            for (index, slice) in slices.enumerated() {
                let payload = FollowerHistorySlice(
                    seq: index + 1,
                    of: slices.count,
                    readings: slice
                )
                do {
                    let sliceData = try encoder.encode(payload)
                    let encrypted = try messenger.encrypt(data: sliceData)
                    try await FollowerPushSender.shared.sendStatus(encryptedStatus: encrypted, to: follower)
                } catch {
                    // Each slice stands alone — the follower merges them by
                    // timestamp — so one that fails to send costs a gap in the
                    // chart rather than the whole backfill.
                    debug(
                        .remoteControl,
                        "Failed to push history slice \(index + 1)/\(slices.count) to follower \(follower.name): \(error)"
                    )
                }
            }
            debug(
                .remoteControl,
                "Pushed \(slices.count) history slice(s) covering \(window) h to follower \(follower.name)"
            )
        } catch {
            debug(.remoteControl, "Failed to build follower history: \(error)")
        }
    }

    /// The readings over the last `hours`, newest first, thinned to
    /// `historyResolution`.
    private func fetchHistoryReadings(hours: Int) async throws -> [FollowerStatusSnapshot.Reading] {
        let end = Date()
        let start = end.addingTimeInterval(-Double(hours) * 3600)
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForDateBetween(start: start, end: end),
            key: "date",
            ascending: false,
            // 48 h at a 5-minute cadence, before thinning. Bounded so a corrupt
            // or enormous store cannot pull the whole table into memory.
            fetchLimit: 640
        )

        return await context.perform {
            guard let glucoseResults = results as? [GlucoseStored] else { return [] }

            var thinned: [FollowerStatusSnapshot.Reading] = []
            var lastKept: TimeInterval?
            // Newest first, so this walks backwards in time and keeps the
            // first reading in each quarter hour it reaches.
            for stored in glucoseResults {
                let date = (stored.date ?? Date()).timeIntervalSince1970.rounded()
                if let previous = lastKept, previous - date < Self.historyResolution {
                    continue
                }
                lastKept = date
                thinned.append(
                    FollowerStatusSnapshot.Reading(
                        sgv: Int(stored.glucose),
                        date: date,
                        // Dropped: a trend arrow describes the moment it was
                        // taken, the follower only draws one for the newest
                        // reading, and it is ~20 bytes of every entry.
                        direction: nil
                    )
                )
            }
            return thinned
        }
    }

    /// Splits readings into as few pushes as each will hold.
    ///
    /// Measured rather than estimated: the payload is encrypted and base64'd
    /// before it is sent, and APNS answers anything over 4 KB with a 413 that
    /// the follower only ever sees as a push that never arrived.
    static func slicedForPush(
        _ readings: [FollowerStatusSnapshot.Reading],
        using encoder: JSONEncoder
    ) throws -> [[FollowerStatusSnapshot.Reading]] {
        var slices: [[FollowerStatusSnapshot.Reading]] = []
        var current: [FollowerStatusSnapshot.Reading] = []

        func fits(_ candidate: [FollowerStatusSnapshot.Reading]) throws -> Bool {
            // Probed with two-digit counters so the measurement is never
            // smaller than the slice actually sent.
            let probe = FollowerHistorySlice(seq: 99, of: 99, readings: candidate)
            let size = FollowerStatusSnapshot.projectedPayloadSize(
                plaintextBytes: try encoder.encode(probe).count
            )
            return size <= FollowerStatusSnapshot.apnsPayloadLimit
        }

        for reading in readings {
            current.append(reading)
            if try fits(current) { continue }

            current.removeLast()
            // A single reading that will not fit means the budget is gone;
            // nothing further can be sent either.
            guard !current.isEmpty else { return slices }
            slices.append(current)
            if slices.count == maximumHistorySlices { return slices }
            current = [reading]
        }

        if !current.isEmpty, slices.count < maximumHistorySlices {
            slices.append(current)
        }
        return slices
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
                    let snapshotData = try personalised.encodedWithinPushLimit(using: encoder)
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

    // MARK: - Snapshot assembly

    private func buildSnapshot() async throws -> FollowerStatusSnapshot {
        let readings = try await fetchReadings()
        let determination = try await fetchDetermination()
        let tempTarget = try await fetchActiveTempTarget()
        let override = try await fetchActiveOverride()
        let boluses = try await fetchBoluses()
        let carbs = try await fetchCarbs()

        let iob = iobService.currentIOB.map { Double(truncating: $0 as NSNumber) }
        let settings = settingsManager.settings

        // The pump's own state, not a record of what was asked for: a
        // suspension that failed to reach the pump must never read as success
        // on a follower's screen.
        let suspended = apsManager.isSuspended
        let suspension = suspended ? FollowerSuspensionManager.shared.current : nil

        // Sent so the follower's chart can colour a reading the way the host's
        // own chart colours it, rather than by the follower's alert thresholds
        // — which are a different question with different numbers.
        let ranges = FollowerStatusSnapshot.GlucoseRanges(
            low: Double(truncating: settings.low as NSNumber),
            high: Double(truncating: settings.high as NSNumber),
            target: Double(truncating: (await currentGlucoseTarget() ?? Self.fallbackTarget) as NSNumber),
            scheme: settings.glucoseColorScheme.rawValue
        )

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
            ranges: ranges,
            boluses: boluses,
            carbs: carbs,
            suspended: suspended,
            suspendedBy: suspension?.followerName,
            suspendedAt: suspension?.requestedAt.timeIntervalSince1970.rounded(),
            suspendAcknowledged: suspension?.acknowledgedAt != nil,
            ai: FollowerPairingManager.shared.followerAIConfig
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
            // encodedWithinPushLimit, which enforces the real budget.
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

    /// The glucose target in force at this moment, from the host's own target
    /// schedule.
    ///
    /// Read straight from storage rather than from a view model: the publisher
    /// runs whether or not the Home screen has ever been on screen.
    private func currentGlucoseTarget() async -> Decimal? {
        let bgTargets = await fileStorage.retrieveAsync(OpenAPS.Settings.bgTargets, as: BGTargets.self)
            ?? BGTargets(from: OpenAPS.defaults(for: OpenAPS.Settings.bgTargets))
        guard let entries = bgTargets?.targets, !entries.isEmpty else { return nil }

        let now = Date()
        let calendar = Calendar.current

        func startOfToday(_ start: String) -> Date? {
            guard let parsed = TherapySettingsUtil.parseTime(start) else { return nil }
            let components = calendar.dateComponents([.hour, .minute, .second], from: parsed)
            return calendar.date(
                bySettingHour: components.hour ?? 0,
                minute: components.minute ?? 0,
                second: components.second ?? 0,
                of: now
            )
        }

        for (index, entry) in entries.enumerated() {
            guard let entryStart = startOfToday(entry.start) else { continue }

            let entryEnd: Date
            if index < entries.count - 1, let nextStart = startOfToday(entries[index + 1].start) {
                entryEnd = nextStart
            } else {
                entryEnd = calendar.date(byAdding: .day, value: 1, to: entryStart) ?? now
            }

            if now >= entryStart, now < entryEnd { return entry.low }
        }

        // Before the first entry of the day the last one is still running, the
        // way it has been since yesterday.
        return entries.last?.low
    }

    /// Stands in when the host has no readable target schedule; the same
    /// default the Home screen starts from.
    private static let fallbackTarget: Decimal = 100

    /// Boluses over the same window the readings cover, newest first.
    ///
    /// Capped well below what six hours could hold: a follower's chart shows
    /// what has been given, not a pump history, and every event costs readings
    /// out of the push budget.
    private func fetchBoluses() async throws -> [FollowerStatusSnapshot.Bolus] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "timestamp >= %@ AND bolus != nil",
                Date.sixHoursAgo as NSDate
            ),
            key: "timestamp",
            ascending: false,
            fetchLimit: 24,
            // The amount lives on the relationship, so prefetch it rather than
            // fault every row separately once the context has them.
            relationshipKeyPathsForPrefetching: ["bolus"]
        )

        return await context.perform {
            guard let events = results as? [PumpEventStored] else { return [] }
            return events.compactMap { event in
                guard let bolus = event.bolus, let amount = bolus.amount else { return nil }
                let units = Double(truncating: amount)
                guard units > 0 else { return nil }
                return FollowerStatusSnapshot.Bolus(
                    // Two decimals is finer than any pump delivers, and the
                    // digits beyond it are float noise in the payload.
                    a: (units * 100).rounded() / 100,
                    t: (event.timestamp ?? Date()).timeIntervalSince1970.rounded(),
                    s: bolus.isSMB ? true : nil
                )
            }
        }
    }

    /// Carb entries over the same window, newest first.
    ///
    /// The fat/protein entries Trio derives from a meal are left out: they are
    /// not something anyone ate at that moment, and explaining that on a
    /// follower's chart would cost more than it tells.
    private func fetchCarbs() async throws -> [FollowerStatusSnapshot.CarbEntry] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(
                format: "date >= %@ AND carbs > 0 AND isFPU == NO",
                Date.sixHoursAgo as NSDate
            ),
            key: "date",
            ascending: false,
            fetchLimit: 16,
            propertiesToFetch: ["carbs", "date"]
        )

        return await context.perform {
            guard let rows = results as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let grams = row["carbs"] as? Double, grams > 0 else { return nil }
                return FollowerStatusSnapshot.CarbEntry(
                    g: grams.rounded(),
                    t: ((row["date"] as? Date) ?? Date()).timeIntervalSince1970.rounded()
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
