import Combine
import CoreData
import Foundation
import Swinject
import UserNotifications

/// What a `SiteChangeStored` row tracks: an infusion-site/cannula change or a CGM sensor start.
enum SiteChangeKind: String, CaseIterable, Identifiable {
    case site
    case sensor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .site: return String(localized: "Pump Site")
        case .sensor: return String(localized: "CGM Sensor")
        }
    }
}

/// How a `SiteChangeStored` row was created.
enum SiteChangeSource: String {
    case auto
    case manual

    var displayName: String {
        switch self {
        case .auto: return String(localized: "Auto")
        case .manual: return String(localized: "Manual")
        }
    }
}

/// Pure dedup-window logic for mirrored site/sensor change events, so it stays unit-testable.
/// Two records within the window describe the same physical change (e.g. a Rewind and a
/// SiteChange emitted by the pump for one cannula swap, or a manual log next to an auto one).
enum SiteChangeDedup {
    /// ± window in which two change records count as the same change (60 minutes).
    static let windowInterval: TimeInterval = 60 * 60

    static func isDuplicate(existing: [Date], candidate: Date) -> Bool {
        existing.contains { abs($0.timeIntervalSince(candidate)) <= windowInterval }
    }
}

/// Pure, dependency-free heuristic for "this site may be absorbing poorly": both insulin
/// use and mean glucose have climbed substantially versus the first days after the site
/// was placed. Advisory only - it never doses and its output is only ever a notification.
enum SiteDegradationPolicy {
    struct Input {
        /// Mean 24 h TDD (U) over the baseline window (days 0-2 after the site change).
        var baselineTDD: Double
        /// Mean 24 h TDD (U) over the last 24 hours.
        var recentTDD: Double
        /// Mean glucose (mg/dL) over the baseline window.
        var baselineMeanBG: Double
        /// Mean glucose (mg/dL) over the last 24 hours.
        var recentMeanBG: Double
        /// Hours since the site change.
        var siteAgeHours: Double
        /// Hours of data coverage inside the baseline window.
        var baselineHours: Double
        /// Whether both TDD and glucose baseline samples exist.
        var hasBaselineSamples: Bool
        /// Whether both TDD and glucose samples exist for the last 24 hours.
        var hasRecentSamples: Bool
    }

    static let minimumSiteAgeHours: Double = 72
    static let minimumBaselineHours: Double = 36
    static let tddRiseRatio = 1.2
    static let bgRiseRatio = 1.15

    static func evaluate(_ input: Input) -> Bool {
        guard input.hasBaselineSamples, input.hasRecentSamples else { return false }
        guard input.siteAgeHours >= minimumSiteAgeHours else { return false }
        guard input.baselineHours >= minimumBaselineHours else { return false }
        guard input.baselineTDD > 0, input.baselineMeanBG > 0 else { return false }
        return input.recentTDD > tddRiseRatio * input.baselineTDD &&
            input.recentMeanBG > bgRiseRatio * input.baselineMeanBG
    }
}

/// Tracks pump-site and CGM-sensor lifecycles: mirrors pump SiteChange/Rewind events and
/// Nightscout "Sensor Start" state into `SiteChangeStored`, accepts manual logs, and raises
/// opt-in, advisory reminders. It never modifies pump state and never doses.
protocol SiteLifecycleManager {
    func refreshSensorStart() async
    func logManualSiteChange(kind: SiteChangeKind, location: SiteBodyLocation?, note: String?, date: Date) async
}

final class BaseSiteLifecycleManager: SiteLifecycleManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!

    private enum Config {
        /// How far back pump events are scanned for site changes.
        static let autoDetectLookbackInterval: TimeInterval = 48 * 60 * 60
        /// Baseline window after a site change used by the degradation heuristic.
        static let baselineWindowInterval: TimeInterval = 48 * 60 * 60
        /// Recent comparison window for the degradation heuristic.
        static let recentWindowInterval: TimeInterval = 24 * 60 * 60
        static let reminderNotificationIdentifier = "Trio.siteChangeReminder"
        static let degradationNotificationIdentifier = "Trio.siteDegradation"
    }

    /// The site-change date the last reminder was sent for.
    @Persisted(key: "SiteTracker.lastSiteReminderFor") private var lastSiteReminderFor: Date = .distantPast
    /// When the last reminder was sent (re-remind each further full interval).
    @Persisted(key: "SiteTracker.lastSiteReminderDate") private var lastSiteReminderDate: Date = .distantPast
    /// The site-change date the degradation notice was sent for (one notice per site).
    @Persisted(key: "SiteTracker.lastDegradationAlertFor") private var lastDegradationAlertFor: Date = .distantPast

    private let context = CoreDataStack.shared.newTaskContext()
    private let center = UNUserNotificationCenter.current()
    private var subscriptions = Set<AnyCancellable>()
    private let timer = DispatchTimer(timeInterval: 30 * 60)

    init(resolver: Resolver) {
        injectServices(resolver)

        changedObjectsOnManagedObjectContextDidSavePublisher(observing: .inserted)
            .filteredByEntityName("PumpEventStored")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.syncAutoSiteChanges() }
            }
            .store(in: &subscriptions)

        timer.publisher
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { await self.tick() }
            }
            .store(in: &subscriptions)
        timer.resume()

        Task { [weak self] in
            guard let self = self else { return }
            await self.syncAutoSiteChanges()
            await self.tick()
        }
    }

    private func tick() async {
        await refreshSensorStart()
        await evaluateReminder()
        await evaluateDegradation()
    }

    // MARK: - Auto-detection from pump events

    /// Mirrors SiteChange (pods, infusion sets) and Rewind (tubed pumps) pump events from
    /// the last 48 h into `SiteChangeStored`, deduplicating within ±60 min so a Rewind and
    /// a SiteChange for the same physical change collapse into one record.
    private func syncAutoSiteChanges() async {
        do {
            let lookback = Date().addingTimeInterval(-Config.autoDetectLookbackInterval)
            let pumpResults = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: PumpEventStored.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "timestamp >= %@ AND type IN %@",
                    lookback as NSDate,
                    [PumpEventStored.EventType.siteChange.rawValue, PumpEventStored.EventType.rewind.rawValue]
                ),
                key: "timestamp",
                ascending: true
            )
            let candidateDates: [Date] = try await context.perform {
                guard let events = pumpResults as? [PumpEventStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }
                return events.compactMap(\.timestamp)
            }
            guard !candidateDates.isEmpty else { return }

            let existingResults = try await fetchSiteChanges(
                kind: .site,
                since: lookback.addingTimeInterval(-SiteChangeDedup.windowInterval)
            )
            try await context.perform {
                guard let existing = existingResults as? [SiteChangeStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }
                var knownDates = existing.compactMap(\.date)
                for candidate in candidateDates.sorted() {
                    guard !SiteChangeDedup.isDuplicate(existing: knownDates, candidate: candidate) else { continue }
                    self.insertSiteChange(kind: .site, source: .auto, date: candidate, location: nil, note: nil)
                    knownDates.append(candidate)
                }
                guard self.context.hasChanges else { return }
                try self.context.save()
                debug(.service, "Site tracker mirrored pump site change event(s)")
            }
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Site tracker auto-detection failed: \(error)")
        }
    }

    // MARK: - Sensor detection from CGM state

    /// Mirrors the most recent "Sensor Start" treatment from monitor/cgm-state.json into
    /// `SiteChangeStored` (kind sensor), deduplicating within ±60 min.
    func refreshSensorStart() async {
        guard let treatments = await storage.retrieveAsync(OpenAPS.Monitor.cgmState, as: [NightscoutTreatment].self)
        else { return }
        let sensorStarts = treatments
            .filter { $0.eventType == .nsSensorChange }
            .compactMap(\.createdAt)
        guard let latest = sensorStarts.max() else { return }

        do {
            let existingResults = try await fetchSiteChanges(
                kind: .sensor,
                since: latest.addingTimeInterval(-2 * SiteChangeDedup.windowInterval)
            )
            try await context.perform {
                guard let existing = existingResults as? [SiteChangeStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }
                let knownDates = existing.compactMap(\.date)
                guard !SiteChangeDedup.isDuplicate(existing: knownDates, candidate: latest) else { return }
                self.insertSiteChange(kind: .sensor, source: .auto, date: latest, location: nil, note: nil)
                guard self.context.hasChanges else { return }
                try self.context.save()
                debug(.service, "Site tracker recorded sensor start")
            }
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Site tracker sensor detection failed: \(error)")
        }
    }

    // MARK: - Manual logging

    /// Stores a manually logged change. Site changes also insert a `PumpEventStored` row
    /// (like external insulin does) so the existing pipelines upload a Site Change
    /// treatment to Nightscout. Auto-detected changes never do this - they came from one.
    func logManualSiteChange(kind: SiteChangeKind, location: SiteBodyLocation?, note: String?, date: Date) async {
        // restrict entry to now or past
        let timestamp = date > Date() ? Date() : date
        await context.perform {
            self.insertSiteChange(kind: kind, source: .manual, date: timestamp, location: location, note: note)

            if kind == .site {
                let newPumpEvent = PumpEventStored(context: self.context)
                newPumpEvent.id = UUID().uuidString
                newPumpEvent.timestamp = timestamp
                newPumpEvent.type = PumpEventStored.EventType.siteChange.rawValue
                newPumpEvent.isUploadedToNS = false
                newPumpEvent.isUploadedToHealth = false
                newPumpEvent.isUploadedToTidepool = false
            }

            do {
                guard self.context.hasChanges else { return }
                try self.context.save()
                debug(.service, "Site tracker saved manual \(kind.rawValue) change")
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to save manual site change: \(error)")
            }
        }
    }

    // MARK: - Reminders

    /// Sends an opt-in reminder once the current site is older than the configured
    /// interval, then again after each further full interval. This intentionally covers
    /// cannula/site age only - pod expiry alerts stay with the pump plugin.
    private func evaluateReminder() async {
        guard settingsManager.settings.siteReminderEnabled else { return }
        guard let siteDate = await latestChangeDate(kind: .site) else { return }

        let intervalDays = max(Double(truncating: settingsManager.settings.siteReminderIntervalDays as NSNumber), 1)
        let interval = intervalDays * 24 * 60 * 60
        let now = Date()
        let age = now.timeIntervalSince(siteDate)
        guard age >= interval else { return }

        // At most one reminder per site per full interval multiple.
        let alreadyRemindedForThisSite = abs(lastSiteReminderFor.timeIntervalSince(siteDate)) < 1
        if alreadyRemindedForThisSite, now.timeIntervalSince(lastSiteReminderDate) < interval {
            return
        }

        let days = Int(age / (24 * 60 * 60))
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Site Change Reminder", comment: "Site change reminder notification title")
        content.body = String(
            localized: "Your pump site is \(days) days old. Consider planning a site change.",
            comment: "Site change reminder notification body"
        )
        content.sound = .default
        content.interruptionLevel = .active

        center.removeDeliveredNotifications(withIdentifiers: [Config.reminderNotificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Config.reminderNotificationIdentifier])
        center.add(UNNotificationRequest(
            identifier: Config.reminderNotificationIdentifier,
            content: content,
            trigger: nil
        ))

        lastSiteReminderFor = siteDate
        lastSiteReminderDate = now
        debug(.service, "Site tracker sent site change reminder (site age \(days) d)")
    }

    // MARK: - Degradation heuristic

    /// Compares insulin use and mean glucose of the last 24 h against the first days after
    /// the site change and raises one advisory notification per site when both have climbed.
    private func evaluateDegradation() async {
        guard settingsManager.settings.siteDegradationAlertsEnabled else { return }
        guard let siteDate = await latestChangeDate(kind: .site) else { return }
        // One notice per site.
        guard abs(lastDegradationAlertFor.timeIntervalSince(siteDate)) >= 1 else { return }

        let now = Date()
        let siteAgeHours = now.timeIntervalSince(siteDate) / 3600
        guard siteAgeHours >= SiteDegradationPolicy.minimumSiteAgeHours else { return }

        do {
            let baselineEnd = siteDate.addingTimeInterval(Config.baselineWindowInterval)
            let recentStart = now.addingTimeInterval(-Config.recentWindowInterval)

            let baselineTDD = try await tddSamples(from: siteDate, to: baselineEnd)
            let recentTDD = try await tddSamples(from: recentStart, to: now)
            let baselineBG = try await glucoseValues(from: siteDate, to: baselineEnd)
            let recentBG = try await glucoseValues(from: recentStart, to: now)

            let baselineHours = (baselineTDD.map(\.date).max().map { $0.timeIntervalSince(siteDate) } ?? 0) / 3600

            let input = SiteDegradationPolicy.Input(
                baselineTDD: mean(baselineTDD.map(\.value)),
                recentTDD: mean(recentTDD.map(\.value)),
                baselineMeanBG: mean(baselineBG),
                recentMeanBG: mean(recentBG),
                siteAgeHours: siteAgeHours,
                baselineHours: baselineHours,
                hasBaselineSamples: !baselineTDD.isEmpty && !baselineBG.isEmpty,
                hasRecentSamples: !recentTDD.isEmpty && !recentBG.isEmpty
            )

            guard SiteDegradationPolicy.evaluate(input) else { return }

            let content = UNMutableNotificationContent()
            content.title = String(localized: "Site Check Suggested", comment: "Site degradation notification title")
            content.body = String(
                localized: "Insulin use and glucose have both climbed since this site was placed. If highs persist, consider whether the site is still absorbing well.",
                comment: "Site degradation notification body"
            )
            content.sound = .default
            content.interruptionLevel = .active

            center.removeDeliveredNotifications(withIdentifiers: [Config.degradationNotificationIdentifier])
            center.removePendingNotificationRequests(withIdentifiers: [Config.degradationNotificationIdentifier])
            center.add(UNNotificationRequest(
                identifier: Config.degradationNotificationIdentifier,
                content: content,
                trigger: nil
            ))

            lastDegradationAlertFor = siteDate
            debug(.service, "Site tracker sent site degradation notice")
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Site degradation evaluation failed: \(error)")
        }
    }

    // MARK: - Fetch helpers

    private func fetchSiteChanges(kind: SiteChangeKind, since: Date) async throws -> Any {
        try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: SiteChangeStored.self,
            onContext: context,
            predicate: NSPredicate(format: "kind == %@ AND date >= %@", kind.rawValue, since as NSDate),
            key: "date",
            ascending: true
        )
    }

    private func latestChangeDate(kind: SiteChangeKind) async -> Date? {
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: SiteChangeStored.self,
                onContext: context,
                predicate: NSPredicate(
                    format: "kind == %@ AND date >= %@",
                    kind.rawValue,
                    Date().addingTimeInterval(-180 * 24 * 60 * 60) as NSDate
                ),
                key: "date",
                ascending: false,
                fetchLimit: 1
            )
            return await context.perform {
                (results as? [SiteChangeStored])?.first?.date
            }
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Site tracker fetch failed: \(error)")
            return nil
        }
    }

    /// Rolling 24 h TDD samples (one per loop cycle) inside the window.
    private func tddSamples(from start: Date, to end: Date) async throws -> [(date: Date, value: Double)] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: TDDStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForDateBetween(start: start, end: end),
            key: "date",
            ascending: true,
            batchSize: 100,
            propertiesToFetch: ["date", "total"]
        )
        return try await context.perform {
            guard let samples = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }
            return samples.compactMap { sample -> (date: Date, value: Double)? in
                guard let date = sample["date"] as? Date,
                      let total = sample["total"] as? NSDecimalNumber,
                      total.doubleValue > 0
                else { return nil }
                return (date: date, value: total.doubleValue)
            }
        }
    }

    private func glucoseValues(from start: Date, to end: Date) async throws -> [Double] {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate.predicateForDateBetween(start: start, end: end),
            key: "date",
            ascending: true,
            batchSize: 100,
            propertiesToFetch: ["glucose"]
        )
        return try await context.perform {
            guard let samples = results as? [[String: Any]] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }
            return samples.compactMap { ($0["glucose"] as? NSNumber)?.doubleValue }
        }
    }

    private func mean(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Must be called inside `context.perform`.
    private func insertSiteChange(
        kind: SiteChangeKind,
        source: SiteChangeSource,
        date: Date,
        location: SiteBodyLocation?,
        note: String?
    ) {
        let change = SiteChangeStored(context: context)
        change.id = UUID()
        change.date = date
        change.kind = kind.rawValue
        change.source = source.rawValue
        change.location = location?.rawValue
        if let note = note, !note.isEmpty {
            change.note = String(note.prefix(50))
        }
    }
}
