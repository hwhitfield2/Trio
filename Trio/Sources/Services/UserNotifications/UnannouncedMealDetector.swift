import Combine
import CoreData
import Foundation
import Swinject
import UIKit
import UserNotifications

/// What the detector found, for the in-app prompt on the Home screen.
struct UnannouncedMealSuggestion: Equatable {
    /// Total glucose rise across the detection window, in mg/dL.
    let riseMgdl: Int
    /// Length of the detection window in minutes.
    let windowMinutes: Int
    /// The most recent glucose value, in mg/dL.
    let currentGlucoseMgdl: Int
    let date: Date
}

protocol UnannouncedMealObserver {
    @MainActor func unannouncedMealDetected(_ suggestion: UnannouncedMealSuggestion)
}

protocol UnannouncedMealDetectionManager {}

/// Watches incoming glucose for a meal-like rise with no carbs logged and no carbs
/// on board, and prompts the user to log the meal: an in-app prompt (via
/// UnannouncedMealObserver) when the app is active, a local notification otherwise.
/// It only ever prompts - it never doses and never logs anything by itself.
final class BaseUnannouncedMealDetectionManager: UnannouncedMealDetectionManager, Injectable {
    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var broadcaster: Broadcaster!

    private enum Config {
        /// Glucose lookback window.
        static let windowMinutes = 25
        /// The oldest compared reading must be at least this old for a meaningful slope.
        static let minSpanMinutes = 12.0
        /// The newest reading must be no older than this (stale data proves nothing).
        static let maxAgeMinutes = 10.0
        /// Total rise across the window that counts as meal-like.
        static let riseThresholdMgdl = 25
        /// Ignore rises that stay below this level - recovery from a low is not a meal.
        static let glucoseFloorMgdl = 110
        /// No carb entry within this interval for the meal to count as unannounced.
        static let carbFreeMinutes = 90
        /// Minimum time between prompts.
        static let cooldownMinutes = 60.0
        static let notificationIdentifier = "Trio.unannouncedMealNotification"
    }

    @Persisted(key: "UnannouncedMealDetector.lastPromptDate") private var lastPromptDate: Date = .distantPast

    private let backgroundContext = CoreDataStack.shared.newTaskContext()
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        glucoseStorage.updatePublisher
            .receive(on: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.evaluate()
                }
            }
            .store(in: &subscriptions)
    }

    private func evaluate() async {
        guard settingsManager.settings.unannouncedMealDetectionEnabled else { return }
        guard Date().timeIntervalSince(lastPromptDate) > Config.cooldownMinutes * 60 else { return }

        do {
            guard let suggestion = try await detectMealLikeRise() else { return }
            guard try await hasNoRecentCarbs(), await hasNoCarbsOnBoard() else { return }

            lastPromptDate = Date()
            debug(
                .service,
                "Unannounced meal detected: +\(suggestion.riseMgdl) mg/dL over \(suggestion.windowMinutes) min, no carbs logged"
            )
            await prompt(with: suggestion)
        } catch {
            debug(.service, "Unannounced meal detection failed: \(error)")
        }
    }

    // MARK: - Detection

    /// Returns a suggestion when the recent glucose curve looks like an eaten meal:
    /// fresh data, a sustained rise above the threshold, still rising now, and the
    /// current value above the floor.
    private func detectMealLikeRise() async throws -> UnannouncedMealSuggestion? {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: backgroundContext,
            predicate: NSPredicate(
                format: "date >= %@",
                Calendar.current.date(byAdding: .minute, value: -Config.windowMinutes, to: Date())! as NSDate
            ),
            key: "date",
            ascending: false,
            fetchLimit: 10
        )

        return try await backgroundContext.perform {
            guard let readings = results as? [GlucoseStored] else {
                throw CoreDataError.fetchError(function: #function, file: #file)
            }
            // Newest first. Need enough points for a trend and a fresh newest value.
            guard readings.count >= 3,
                  let newest = readings.first,
                  let newestDate = newest.date,
                  let oldest = readings.last,
                  let oldestDate = oldest.date
            else { return nil }

            guard Date().timeIntervalSince(newestDate) <= Config.maxAgeMinutes * 60 else { return nil }
            guard newestDate.timeIntervalSince(oldestDate) >= Config.minSpanMinutes * 60 else { return nil }

            let rise = Int(newest.glucose) - Int(oldest.glucose)
            let stillRising = newest.glucose > readings[1].glucose

            guard rise >= Config.riseThresholdMgdl,
                  stillRising,
                  newest.glucose >= Int16(Config.glucoseFloorMgdl)
            else { return nil }

            return UnannouncedMealSuggestion(
                riseMgdl: rise,
                windowMinutes: Int(newestDate.timeIntervalSince(oldestDate) / 60),
                currentGlucoseMgdl: Int(newest.glucose),
                date: newestDate
            )
        }
    }

    /// True when no carb entry exists in the last carbFreeMinutes. Future-dated FPU
    /// equivalents from a recent fat/protein entry also count as an announced meal.
    private func hasNoRecentCarbs() async throws -> Bool {
        let results = try await CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: backgroundContext,
            predicate: NSPredicate(
                format: "date >= %@ AND carbs > 0",
                Calendar.current.date(byAdding: .minute, value: -Config.carbFreeMinutes, to: Date())! as NSDate
            ),
            key: "date",
            ascending: false,
            fetchLimit: 1
        )

        return await backgroundContext.perform {
            guard let entries = results as? [CarbEntryStored] else { return false }
            return entries.isEmpty
        }
    }

    /// True when the latest determination reports zero COB (or no recent
    /// determination exists, in which case the carb-entry check above governs).
    private func hasNoCarbsOnBoard() async -> Bool {
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: OrefDetermination.self,
                onContext: backgroundContext,
                predicate: NSPredicate.predicateFor30MinAgoForDetermination,
                key: "deliverAt",
                ascending: false,
                fetchLimit: 1
            )

            return await backgroundContext.perform {
                guard let determinations = results as? [OrefDetermination],
                      let latest = determinations.first
                else { return true }
                return latest.cob <= 0
            }
        } catch {
            return true
        }
    }

    // MARK: - Prompting

    @MainActor private func prompt(with suggestion: UnannouncedMealSuggestion) async {
        if UIApplication.shared.applicationState == .active {
            broadcaster.notify(UnannouncedMealObserver.self, on: .main) {
                $0.unannouncedMealDetected(suggestion)
            }
        } else {
            sendNotification(for: suggestion)
        }
    }

    private func glucoseString(_ mgdl: Int) -> String {
        let units = settingsManager.settings.units
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = units == .mmolL ? 1 : 0
        let value: Decimal = units == .mmolL ? Decimal(mgdl).asMmolL : Decimal(mgdl)
        return (formatter.string(from: value as NSNumber) ?? "\(mgdl)") + " " + units.rawValue
    }

    @MainActor private func sendNotification(for suggestion: UnannouncedMealSuggestion) {
        // Respect the user's carb-notification preference for the push channel.
        guard settingsManager.settings.notificationsCarb else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Possible Unannounced Meal", comment: "Unannounced meal notification title")
        content.body = String(
            localized: "Glucose rose \(glucoseString(suggestion.riseMgdl)) in the last \(suggestion.windowMinutes) min with no carbs logged. Tap to log your meal.",
            comment: "Unannounced meal notification body"
        )
        content.sound = .default
        content.interruptionLevel = .active
        content.userInfo[NotificationAction.key] = NotificationAction.logCarbs.rawValue

        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Config.notificationIdentifier])
        center.removePendingNotificationRequests(withIdentifiers: [Config.notificationIdentifier])
        center.add(UNNotificationRequest(
            identifier: Config.notificationIdentifier,
            content: content,
            trigger: nil
        ))
    }
}
