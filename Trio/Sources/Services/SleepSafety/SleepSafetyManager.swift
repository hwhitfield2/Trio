import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import UserNotifications

/// Sleep-safe overnight mode: during a user-scheduled nightly window it can activate an
/// existing override preset, escalates unacknowledged low-glucose alerts with additional
/// time-sensitive notifications, and can text a caregiver via the existing Twilio service.
///
/// It never creates new dosing paths: override activation reuses the exact preset-enact
/// mechanics the Shortcuts integration uses, and it never cancels an override the user set
/// manually - only the one it activated itself. Trio's normal glucose alarms are untouched;
/// this service only ADDS reminders on top of them.
protocol SleepSafetyManager {
    /// Whether the configured sleep window covers the current time.
    var isWindowActive: Bool { get }
}

enum SleepSafetyError: Error {
    case presetNotFound
}

final class BaseSleepSafetyManager: SleepSafetyManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var overrideStorage: OverrideStorage!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var twilioMessaging: TwilioMessagingManager!

    private enum Config {
        static let escalationNotificationIdentifier = "Trio.sleepEscalation"
        /// Activation is only attempted this close to the window start, so a launch in the
        /// middle of the night never enacts an override the user did not expect.
        static let startGraceMinutes = 5
    }

    /// The OverrideStored.id of the preset WE activated for the current window ("" = none).
    @Persisted(key: "SleepSafety.activatedOverrideID") private var activatedOverrideID: String = ""
    /// When we activated it.
    @Persisted(key: "SleepSafety.activatedAt") private var activatedAt: Date = .distantPast
    /// When the current low episode began (.distantPast = no episode).
    @Persisted(key: "SleepSafety.episodeStartDate") private var episodeStartDate: Date = .distantPast
    /// When the last escalation notification was posted.
    @Persisted(key: "SleepSafety.lastEscalationDate") private var lastEscalationDate: Date = .distantPast
    /// Whether the caregiver SMS already went out for the current episode.
    @Persisted(key: "SleepSafety.caregiverSentForEpisode") private var caregiverSentForEpisode: Bool = false
    /// Last acknowledgement: the app came to the foreground or alerts were snoozed.
    @Persisted(key: "SleepSafety.lastAckDate") private var lastAckDate: Date = .distantPast

    /// Another override was already running at the window start, so activation is skipped
    /// for this window (user intent wins). Not persisted - a restart simply re-checks.
    private var skippedForCurrentWindow = false

    private let viewContext = CoreDataStack.shared.persistentContainer.viewContext
    private let center = UNUserNotificationCenter.current()
    private let timer = DispatchTimer(timeInterval: 60)
    private var coreDataPublisher: AnyPublisher<Set<NSManagedObjectID>, Never>?
    private var subscriptions = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "BaseSleepSafetyManager.queue", qos: .utility)

    private struct GlucoseReading {
        let value: Int
        let trendSymbol: String?
    }

    init(resolver: Resolver) {
        injectServices(resolver)

        coreDataPublisher =
            changedObjectsOnManagedObjectContextDidSavePublisher()
                .receive(on: queue)
                .share()
                .eraseToAnyPublisher()

        coreDataPublisher?
            .filteredByEntityName("GlucoseStored")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.evaluateGlucose()
                }
            }
            .store(in: &subscriptions)

        timer.publisher
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task { @MainActor in
                    await self.tick()
                }
            }
            .store(in: &subscriptions)
        timer.resume()

        // Opening the app counts as acknowledging an overnight low.
        Foundation.NotificationCenter.default
            .publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.lastAckDate = Date()
            }
            .store(in: &subscriptions)

        broadcaster.register(SnoozeObserver.self, observer: self)

        // Reconciliation: if the app was killed overnight while our override was active
        // and the window has since ended, end it now.
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            if !self.activatedOverrideID.isEmpty, !self.isWindowActive {
                await self.deactivateManagedOverride()
            }
        }
    }

    var isWindowActive: Bool {
        SleepSafetyPolicy.isInWindow(
            now: Date(),
            startMinutes: Int(truncating: settingsManager.settings.sleepWindowStartMinutes as NSNumber),
            endMinutes: Int(truncating: settingsManager.settings.sleepWindowEndMinutes as NSNumber)
        )
    }

    // MARK: - Window handling (1-minute heartbeat)

    @MainActor private func tick() async {
        let settings = settingsManager.settings
        let startMinutes = Int(truncating: settings.sleepWindowStartMinutes as NSNumber)
        let endMinutes = Int(truncating: settings.sleepWindowEndMinutes as NSNumber)
        let now = Date()
        let active = SleepSafetyPolicy.isInWindow(now: now, startMinutes: startMinutes, endMinutes: endMinutes)

        guard active, settings.sleepSafetyEnabled else {
            // Window ended (or the feature was turned off): end OUR override if one is active.
            skippedForCurrentWindow = false
            if !activatedOverrideID.isEmpty {
                await deactivateManagedOverride()
            }
            return
        }

        let presetID = settings.sleepOverridePresetID
        if !presetID.isEmpty, activatedOverrideID.isEmpty, !skippedForCurrentWindow,
           let minutesIn = SleepSafetyPolicy.minutesSinceWindowStart(
               now: now,
               startMinutes: startMinutes,
               endMinutes: endMinutes
           ),
           minutesIn <= Config.startGraceMinutes
        {
            await activateConfiguredPreset(id: presetID)
        }
    }

    /// Enacts the configured preset at the window start - but only when no other override
    /// is running, so a manually chosen override always wins.
    @MainActor private func activateConfiguredPreset(id: String) async {
        do {
            let activeOverrideIDs = try await overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 0)
            guard activeOverrideIDs.isEmpty else {
                skippedForCurrentWindow = true
                debug(.service, "Sleep safety: another override is active at window start, keeping it and skipping ours")
                return
            }
            try await enactPreset(id: id)
            activatedOverrideID = id
            activatedAt = Date()
            debug(.service, "Sleep safety: activated the sleep window override preset")
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Sleep safety could not activate the override preset: \(error)")
        }
    }

    /// Canonical preset-enact mechanics (same as OverridePresetsIntentRequest.enactOverride,
    /// without the disable-all step: we only ever enact when nothing else is active).
    @MainActor private func enactPreset(id: String) async throws {
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = startBackgroundTask(withName: "Sleep Safety Override Enact")
        defer { endBackgroundTaskSafely(&backgroundTaskID, taskName: "Sleep Safety Override Enact") }

        let fetchRequest: NSFetchRequest<OverrideStored> = OverrideStored.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "id == %@ AND isPreset == %@", id, true as NSNumber)
        fetchRequest.fetchLimit = 1

        guard let overrideObject = try viewContext.fetch(fetchRequest).first else {
            throw SleepSafetyError.presetNotFound
        }

        overrideObject.enabled = true
        overrideObject.date = Date()
        overrideObject.isUploadedToNS = false

        if viewContext.hasChanges {
            try viewContext.save()
            Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
            await awaitNotification(.didUpdateOverrideConfiguration)
        }
    }

    /// Ends the override WE activated. If the user switched to a different override during
    /// the night, their choice is left untouched and only our bookkeeping is cleared.
    @MainActor private func deactivateManagedOverride() async {
        var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
        backgroundTaskID = startBackgroundTask(withName: "Sleep Safety Override End")
        defer { endBackgroundTaskSafely(&backgroundTaskID, taskName: "Sleep Safety Override End") }

        do {
            let ids = try await overrideStorage.loadLatestOverrideConfigurations(fetchLimit: 0)
            let results = try ids.compactMap { id in
                try viewContext.existingObject(with: id) as? OverrideStored
            }

            if let managedOverride = results.first(where: { $0.id == activatedOverrideID }) {
                // History entry, exactly like the canonical disable path.
                let newOverrideRunStored = OverrideRunStored(context: viewContext)
                newOverrideRunStored.id = UUID()
                newOverrideRunStored.name = managedOverride.name
                newOverrideRunStored.startDate = managedOverride.date ?? .distantPast
                newOverrideRunStored.endDate = Date()
                newOverrideRunStored.target = NSDecimalNumber(
                    decimal: overrideStorage.calculateTarget(override: managedOverride)
                )
                newOverrideRunStored.override = managedOverride
                newOverrideRunStored.isUploadedToNS = false

                managedOverride.enabled = false
                managedOverride.isUploadedToNS = false

                if viewContext.hasChanges {
                    try viewContext.save()
                    Foundation.NotificationCenter.default.post(name: .willUpdateOverrideConfiguration, object: nil)
                    await awaitNotification(.didUpdateOverrideConfiguration)
                }
                debug(.service, "Sleep safety: ended the sleep window override")
            } else {
                debug(.service, "Sleep safety: the active override changed overnight, leaving it untouched")
            }

            activatedOverrideID = ""
            activatedAt = .distantPast
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Sleep safety could not end the override: \(error)")
        }
    }

    // MARK: - Low-glucose escalation

    @MainActor private func evaluateGlucose() async {
        let settings = settingsManager.settings
        guard settings.sleepSafetyEnabled, isWindowActive else { return }

        let reading = latestReading()
        let now = Date()

        let config = SleepSafetyPolicy.Config(
            lowThreshold: settings.lowGlucose,
            escalationRepeatMinutes: Double(truncating: settings.sleepEscalationRepeatMinutes as NSNumber),
            caregiverEnabled: settings.sleepCaregiverEscalationEnabled,
            caregiverEscalationMinutes: Double(truncating: settings.sleepCaregiverEscalationMinutes as NSNumber)
        )
        let state = SleepSafetyPolicy.State(
            glucose: reading?.value,
            episodeStartDate: episodeStartDate == .distantPast ? nil : episodeStartDate,
            lastEscalationDate: lastEscalationDate == .distantPast ? nil : lastEscalationDate,
            lastAckDate: lastAckDate == .distantPast ? nil : lastAckDate,
            caregiverSentForEpisode: caregiverSentForEpisode
        )

        switch SleepSafetyPolicy.action(state: state, config: config, now: now) {
        case .none:
            break
        case .startEpisode:
            // Stage 1 is Trio's normal low alarm - only record when the episode began.
            episodeStartDate = now
            caregiverSentForEpisode = false
        case .resetEpisode:
            episodeStartDate = .distantPast
            caregiverSentForEpisode = false
        case .escalate:
            if let reading = reading {
                scheduleEscalationNotification(reading: reading)
                lastEscalationDate = now
            }
        case .notifyCaregiver:
            if let reading = reading {
                await sendCaregiverEscalation(reading: reading, now: now)
            }
        case .escalateAndNotifyCaregiver:
            if let reading = reading {
                scheduleEscalationNotification(reading: reading)
                lastEscalationDate = now
                await sendCaregiverEscalation(reading: reading, now: now)
            }
        }
    }

    @MainActor private func latestReading() -> GlucoseReading? {
        do {
            let readings = try CoreDataStack.shared.fetchEntities(
                ofType: GlucoseStored.self,
                onContext: viewContext,
                predicate: NSPredicate.predicateFor30MinAgo,
                key: "date",
                ascending: false,
                fetchLimit: 1
            ) as? [GlucoseStored] ?? []
            return readings.first.map { GlucoseReading(value: Int($0.glucose), trendSymbol: $0.directionEnum?.symbol) }
        } catch {
            warning(.service, "Sleep safety could not fetch glucose", error: error)
            return nil
        }
    }

    /// Posts an ADDITIONAL time-sensitive reminder. Trio's normal glucose alarms keep their
    /// own identifier and are never removed or replaced by this.
    @MainActor private func scheduleEscalationNotification(reading: GlucoseReading) {
        let units = settingsManager.settings.units
        var glucoseText = reading.value.formatted(for: units) + " " + units.rawValue
        if let trendSymbol = reading.trendSymbol {
            glucoseText += " " + trendSymbol
        }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Overnight Low — please respond", comment: "Sleep safety escalation title")
        content.body = String(
            localized: "Glucose is still low: \(glucoseText). Open Trio or snooze to acknowledge.",
            comment: "Sleep safety escalation body"
        )
        content.sound = UNNotificationSound(named: UNNotificationSoundName(rawValue: "cartman_low.wav"))
        content.interruptionLevel = .timeSensitive
        content.userInfo[NotificationAction.key] = NotificationAction.snooze.rawValue
        content.categoryIdentifier = NotificationCategoryIdentifier.trioAlert.rawValue

        center.removeDeliveredNotifications(withIdentifiers: [Config.escalationNotificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Config.escalationNotificationIdentifier])
        center.add(UNNotificationRequest(
            identifier: Config.escalationNotificationIdentifier,
            content: content,
            trigger: nil
        ))
        debug(.service, "Sleep safety: escalation notification posted")
    }

    @MainActor private func sendCaregiverEscalation(reading: GlucoseReading, now: Date) async {
        guard settingsManager.settings.twilioEnabled, twilioMessaging.isConfigured else { return }

        let units = settingsManager.settings.units
        let valueText = reading.value.formatted(for: units) + " " + units.rawValue
        let minutes = max(Int(now.timeIntervalSince(episodeStartDate) / 60), 0)
        let body = String(
            localized: "Trio sleep safety: low glucose \(valueText) for \(minutes) min with no response.",
            comment: "Sleep safety caregiver SMS body"
        )

        do {
            try await twilioMessaging.sendSleepEscalationMessage(body)
            caregiverSentForEpisode = true
            debug(.service, "Sleep safety: caregiver SMS sent")
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Sleep safety caregiver SMS failed: \(error)")
        }
    }
}

extension BaseSleepSafetyManager: SnoozeObserver {
    @MainActor func snoozeDidChange(_: Date) {
        // Snoozing the alarms counts as acknowledging the overnight low.
        lastAckDate = Date()
    }
}
