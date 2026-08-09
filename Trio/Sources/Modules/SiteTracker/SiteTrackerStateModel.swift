import Combine
import CoreData
import Foundation
import Observation
import SwiftUI

extension SiteTracker {
    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var siteLifecycleManager: SiteLifecycleManager!

        private enum LocalConfig {
            /// All reads self-limit to this window.
            static let historyInterval: TimeInterval = 180 * 24 * 60 * 60
        }

        var units: GlucoseUnits = .mgdL
        var siteChanges: [SiteChangeStored] = []
        var currentSite: SiteChangeStored?
        var currentSensor: SiteChangeStored?

        // MARK: - Settings mirrors (written straight back to TrioSettings)

        var siteReminderEnabled = false {
            didSet {
                guard settingsManager != nil,
                      siteReminderEnabled != settingsManager.settings.siteReminderEnabled else { return }
                settingsManager.settings.siteReminderEnabled = siteReminderEnabled
            }
        }

        var siteReminderIntervalDays = 3 {
            didSet {
                guard settingsManager != nil else { return }
                let newValue = Decimal(siteReminderIntervalDays)
                guard newValue != settingsManager.settings.siteReminderIntervalDays else { return }
                settingsManager.settings.siteReminderIntervalDays = newValue
            }
        }

        var siteDegradationAlertsEnabled = false {
            didSet {
                guard settingsManager != nil,
                      siteDegradationAlertsEnabled != settingsManager.settings.siteDegradationAlertsEnabled
                else { return }
                settingsManager.settings.siteDegradationAlertsEnabled = siteDegradationAlertsEnabled
            }
        }

        private let taskContext = CoreDataStack.shared.newTaskContext()
        let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units
            siteReminderEnabled = settingsManager.settings.siteReminderEnabled
            siteReminderIntervalDays = Int(
                truncating: settingsManager.settings.siteReminderIntervalDays as NSNumber
            )
            siteDegradationAlertsEnabled = settingsManager.settings.siteDegradationAlertsEnabled

            changedObjectsOnManagedObjectContextDidSavePublisher()
                .filteredByEntityName("SiteChangeStored")
                .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in
                    guard let self = self else { return }
                    Task { await self.loadRecentChanges() }
                }
                .store(in: &lifetime)

            Task { await self.loadRecentChanges() }
        }

        // MARK: - Loading (fetch IDs on a task context, materialize on the view context)

        @MainActor func loadRecentChanges() async {
            do {
                let ids = try await fetchChangeIDs()
                let changes = try ids.compactMap { id in
                    try viewContext.existingObject(with: id) as? SiteChangeStored
                }
                siteChanges = changes
                currentSite = changes.first { $0.kind == SiteChangeKind.site.rawValue }
                currentSensor = changes.first { $0.kind == SiteChangeKind.sensor.rawValue }
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to load site changes: \(error)")
            }
        }

        private func fetchChangeIDs() async throws -> [NSManagedObjectID] {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: SiteChangeStored.self,
                onContext: taskContext,
                predicate: NSPredicate(
                    format: "date >= %@",
                    Date().addingTimeInterval(-LocalConfig.historyInterval) as NSDate
                ),
                key: "date",
                ascending: false,
                batchSize: 50
            )
            return try await taskContext.perform {
                guard let changes = results as? [SiteChangeStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }
                return changes.map(\.objectID)
            }
        }

        // MARK: - Actions

        @MainActor func logChange(kind: SiteChangeKind, location: SiteBodyLocation?, note: String, date: Date) async {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            await siteLifecycleManager.logManualSiteChange(
                kind: kind,
                location: location,
                note: trimmedNote.isEmpty ? nil : trimmedNote,
                date: date
            )
            await loadRecentChanges()
        }

        @MainActor func delete(_ change: SiteChangeStored) {
            viewContext.delete(change)
            do {
                guard viewContext.hasChanges else { return }
                try viewContext.save()
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to delete site change: \(error)")
            }
        }

        @MainActor func updateLocation(of change: SiteChangeStored, to location: SiteBodyLocation?) {
            change.location = location?.rawValue
            do {
                guard viewContext.hasChanges else { return }
                try viewContext.save()
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to update site change location: \(error)")
            }
        }

        // MARK: - Derived display data

        var rotationSummary: [SiteRotationMath.Entry] {
            let entries = siteChanges
                .filter { $0.kind == SiteChangeKind.site.rawValue }
                .compactMap { change -> (location: SiteBodyLocation?, date: Date)? in
                    guard let date = change.date else { return nil }
                    return (location: change.location.flatMap(SiteBodyLocation.init(rawValue:)), date: date)
                }
            return SiteRotationMath.summary(of: entries)
        }

        var locatedSiteChangeCount: Int {
            rotationSummary.reduce(0) { $0 + $1.count }
        }

        func ageString(since date: Date?) -> String {
            guard let date = date else { return "—" }
            let interval = max(Date().timeIntervalSince(date), 0)
            let totalMinutes = Int(interval / 60)
            let days = totalMinutes / (24 * 60)
            let hours = (totalMinutes % (24 * 60)) / 60
            let minutes = totalMinutes % 60
            if days > 0 {
                return "\(days)d \(hours)h"
            }
            return "\(hours)h \(minutes)m"
        }

        /// Green while younger than the reminder interval, orange within the following
        /// day, red beyond that (with the default 3-day interval: green <3 d,
        /// orange 3-4 d, red >4 d).
        func siteAgeColor(since date: Date?) -> Color {
            guard let date = date else { return .secondary }
            let ageDays = Date().timeIntervalSince(date) / (24 * 60 * 60)
            let interval = Double(siteReminderIntervalDays)
            if ageDays < interval { return .green }
            if ageDays < interval + 1 { return .orange }
            return .red
        }
    }
}
