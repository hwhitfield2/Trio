import Combine
import CoreData
import Foundation
import Swinject

/// A single glucose reading used by the pure post-meal outcome math. Values are mg/dL.
struct FoodGlucoseReading: Equatable {
    let date: Date
    let glucose: Int
}

/// Pure, dependency-free math for post-meal glucose outcomes so it stays unit-testable.
/// All glucose values are mg/dL; conversion to display units happens in the views.
enum FoodOutcomeMath {
    struct Outcome: Equatable {
        let startGlucose: Int
        let peakDelta: Int
        let endGlucose: Int
        let hypoWithin4h: Bool
        let endedAboveRange: Bool
        /// False when no reading existed near the meal time - the outcome is a
        /// degenerate placeholder with zeroed values and cleared flags.
        let hasStartReading: Bool
    }

    static let hypoThresholdMgdl = 70
    static let aboveRangeThresholdMgdl = 180
    /// A reading must exist within this interval of the meal time to anchor the outcome.
    static let startToleranceInterval: TimeInterval = 20 * 60
    /// Peak rise is measured across the first two hours after the meal.
    static let peakWindowInterval: TimeInterval = 2 * 60 * 60
    /// The outcome window ends four hours after the meal.
    static let outcomeWindowInterval: TimeInterval = 4 * 60 * 60
    /// The end reading must lie within this interval of the four-hour mark.
    static let endToleranceInterval: TimeInterval = 30 * 60

    /// The upsert key for library items: lowercased, whitespace-trimmed name.
    static func normalizedName(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Computes the post-meal outcome from raw readings around `mealDate`.
    /// Missing data degrades gracefully: no start reading yields a degenerate outcome,
    /// no peak reading yields peakDelta 0, no end reading yields endGlucose 0.
    static func outcome(mealDate: Date, readings: [FoodGlucoseReading]) -> Outcome {
        let start = readings
            .filter { abs($0.date.timeIntervalSince(mealDate)) <= startToleranceInterval }
            .min { abs($0.date.timeIntervalSince(mealDate)) < abs($1.date.timeIntervalSince(mealDate)) }

        guard let start = start else {
            return Outcome(
                startGlucose: 0,
                peakDelta: 0,
                endGlucose: 0,
                hypoWithin4h: false,
                endedAboveRange: false,
                hasStartReading: false
            )
        }

        let windowEnd = mealDate.addingTimeInterval(outcomeWindowInterval)
        let afterMeal = readings.filter { $0.date > mealDate && $0.date <= windowEnd }

        let peak = afterMeal
            .filter { $0.date.timeIntervalSince(mealDate) <= peakWindowInterval }
            .map(\.glucose)
            .max()
        let peakDelta = peak.map { $0 - start.glucose } ?? 0

        let endGlucose = readings
            .filter { abs($0.date.timeIntervalSince(windowEnd)) <= endToleranceInterval }
            .min { abs($0.date.timeIntervalSince(windowEnd)) < abs($1.date.timeIntervalSince(windowEnd)) }?
            .glucose ?? 0

        let hypoWithin4h = afterMeal.contains { $0.glucose < hypoThresholdMgdl }
        let endedAboveRange = endGlucose > aboveRangeThresholdMgdl

        return Outcome(
            startGlucose: start.glucose,
            peakDelta: peakDelta,
            endGlucose: endGlucose,
            hypoWithin4h: hypoWithin4h,
            endedAboveRange: endedAboveRange,
            hasStartReading: true
        )
    }
}

/// Maintains the personal food library: captures named carb entries into library items,
/// computes neutral post-meal outcome stats, and imports meal presets on request.
/// Purely observational - it never doses and never modifies carb entries.
protocol FoodLibraryManager {
    func captureNewEntries() async
    func computePendingOutcomes() async
    func importMealPresets() async -> Int
}

final class BaseFoodLibraryManager: FoodLibraryManager, Injectable {
    private enum Config {
        /// Only capture entries from the recent past on first run.
        static let captureLookbackDays = 7.0
        /// Outcomes are computed once the full window plus a margin has passed.
        static let outcomeDelayHours = 4.5
        /// Outcomes older than this are never computed (glucose may be purged).
        static let outcomeLookbackDays = 14.0
        /// Skip a new usage when one already exists within this interval for the same item.
        static let usageDedupInterval: TimeInterval = 2 * 60
        /// The watch quick-entry writes this note; it is not a food name.
        static let watchDefaultNote = "Via Watch"
    }

    @Persisted(key: "FoodLibrary.lastCaptureDate") private var lastCaptureDate: Date = .distantPast

    private let backgroundContext = CoreDataStack.shared.newTaskContext()
    private var subscriptions = Set<AnyCancellable>()

    init(resolver: Resolver) {
        injectServices(resolver)
        subscribe()
        Task {
            await self.captureNewEntries()
            await self.computePendingOutcomes()
        }
    }

    private func subscribe() {
        changedObjectsOnManagedObjectContextDidSavePublisher(observing: .inserted)
            .filteredByEntityName("CarbEntryStored")
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.global(qos: .background))
            .sink { [weak self] _ in
                guard let self = self else { return }
                Task {
                    await self.captureNewEntries()
                    await self.computePendingOutcomes()
                }
            }
            .store(in: &subscriptions)
    }

    // MARK: - Capture

    /// Upserts a library item (and a usage record) for every named, non-FPU carb entry
    /// saved since the last capture pass.
    func captureNewEntries() async {
        let lookbackLimit = Date().addingTimeInterval(-Config.captureLookbackDays * 24 * 60 * 60)
        let captureStart = max(lastCaptureDate, lookbackLimit)

        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: CarbEntryStored.self,
                onContext: backgroundContext,
                predicate: NSPredicate(
                    format: "date > %@ AND isFPU == NO AND note != nil AND note != ''",
                    captureStart as NSDate
                ),
                key: "date",
                ascending: true
            )

            let newestCaptured: Date? = try await backgroundContext.perform {
                guard let entries = results as? [CarbEntryStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }

                var newestDate: Date?
                for entry in entries {
                    guard let entryDate = entry.date else { continue }
                    newestDate = max(newestDate ?? entryDate, entryDate)
                    self.capture(entry: entry, entryDate: entryDate)
                }

                if self.backgroundContext.hasChanges {
                    try self.backgroundContext.save()
                }
                return newestDate
            }

            if let newestCaptured = newestCaptured, newestCaptured > lastCaptureDate {
                lastCaptureDate = newestCaptured
            }
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Food library capture failed: \(error)")
        }
    }

    /// Must be called inside `backgroundContext.perform`.
    private func capture(entry: CarbEntryStored, entryDate: Date) {
        guard entry.carbs > 0, let note = entry.note, note != Config.watchDefaultNote else { return }
        let normalized = FoodOutcomeMath.normalizedName(note)
        guard !normalized.isEmpty else { return }

        let item: FoodItemStored
        let itemRequest = FoodItemStored.fetchRequest()
        itemRequest.predicate = NSPredicate(format: "normalizedName == %@", normalized)
        itemRequest.fetchLimit = 1
        if let existing = ((try? backgroundContext.fetch(itemRequest)) ?? []).first {
            item = existing
        } else {
            item = FoodItemStored(context: backgroundContext)
            item.id = UUID()
            item.createdAt = entryDate
            item.name = note
            item.normalizedName = normalized
            item.source = "log"
            item.useCount = 0
        }

        // Keep the item's macros in sync with the latest logged serving.
        if item.lastUsedAt == nil || entryDate >= item.lastUsedAt! {
            item.lastUsedAt = entryDate
            item.name = note
            item.carbs = NSDecimalNumber(value: entry.carbs)
            item.fat = NSDecimalNumber(value: entry.fat)
            item.protein = NSDecimalNumber(value: entry.protein)
        }

        // One usage per logged meal: skip when one already exists within the dedup window.
        let usageRequest = FoodUsageStored.fetchRequest()
        usageRequest.predicate = NSPredicate(
            format: "foodItem == %@ AND date >= %@ AND date <= %@",
            item,
            entryDate.addingTimeInterval(-Config.usageDedupInterval) as NSDate,
            entryDate.addingTimeInterval(Config.usageDedupInterval) as NSDate
        )
        usageRequest.fetchLimit = 1
        guard ((try? backgroundContext.fetch(usageRequest)) ?? []).isEmpty else { return }

        let usage = FoodUsageStored(context: backgroundContext)
        usage.id = UUID()
        usage.date = entryDate
        usage.carbs = entry.carbs
        usage.outcomeComputed = false
        usage.foodItem = item
        item.useCount += 1
    }

    // MARK: - Outcomes

    /// Fills in post-meal outcome stats for usages whose four-hour window has fully passed.
    func computePendingOutcomes() async {
        let now = Date()
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: FoodUsageStored.self,
                onContext: backgroundContext,
                predicate: NSPredicate(
                    format: "outcomeComputed == NO AND date <= %@ AND date >= %@",
                    now.addingTimeInterval(-Config.outcomeDelayHours * 60 * 60) as NSDate,
                    now.addingTimeInterval(-Config.outcomeLookbackDays * 24 * 60 * 60) as NSDate
                ),
                key: "date",
                ascending: true
            )

            let pending: [(objectID: NSManagedObjectID, mealDate: Date)] = try await backgroundContext.perform {
                guard let usages = results as? [FoodUsageStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }
                return usages.compactMap { usage in usage.date.map { (usage.objectID, $0) } }
            }

            guard !pending.isEmpty else { return }

            for entry in pending {
                let glucoseResults = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: GlucoseStored.self,
                    onContext: backgroundContext,
                    predicate: NSPredicate.predicateForDateBetween(
                        start: entry.mealDate.addingTimeInterval(-15 * 60),
                        end: entry.mealDate.addingTimeInterval(FoodOutcomeMath.outcomeWindowInterval)
                    ),
                    key: "date",
                    ascending: true
                )

                try await backgroundContext.perform {
                    guard let readings = glucoseResults as? [GlucoseStored] else {
                        throw CoreDataError.fetchError(function: #function, file: #file)
                    }
                    let samples = readings.compactMap { reading in
                        reading.date.map { FoodGlucoseReading(date: $0, glucose: Int(reading.glucose)) }
                    }
                    let outcome = FoodOutcomeMath.outcome(mealDate: entry.mealDate, readings: samples)

                    guard let usage = try? self.backgroundContext.existingObject(with: entry.objectID) as? FoodUsageStored
                    else { return }
                    usage.startGlucose = Int16(clamping: outcome.startGlucose)
                    usage.peakDelta = Int16(clamping: outcome.peakDelta)
                    usage.endGlucose = Int16(clamping: outcome.endGlucose)
                    usage.hypoWithin4h = outcome.hypoWithin4h
                    usage.endedAboveRange = outcome.endedAboveRange
                    usage.outcomeComputed = true
                }
            }

            try await backgroundContext.perform {
                guard self.backgroundContext.hasChanges else { return }
                try self.backgroundContext.save()
            }
            debug(.service, "Food library computed outcomes for \(pending.count) usage(s)")
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Food library outcome computation failed: \(error)")
        }
    }

    // MARK: - Preset import

    /// Creates a library item for every meal preset whose name is not in the library yet.
    /// Returns the number of items imported.
    func importMealPresets() async -> Int {
        do {
            let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                ofType: MealPresetStored.self,
                onContext: backgroundContext,
                predicate: NSPredicate(value: true),
                key: "dish",
                ascending: true
            )

            return try await backgroundContext.perform {
                guard let presets = results as? [MealPresetStored] else {
                    throw CoreDataError.fetchError(function: #function, file: #file)
                }

                var imported = 0
                for preset in presets {
                    guard let dish = preset.dish else { continue }
                    let normalized = FoodOutcomeMath.normalizedName(dish)
                    guard !normalized.isEmpty else { continue }

                    let request = FoodItemStored.fetchRequest()
                    request.predicate = NSPredicate(format: "normalizedName == %@", normalized)
                    request.fetchLimit = 1
                    guard try self.backgroundContext.fetch(request).isEmpty else { continue }

                    let item = FoodItemStored(context: self.backgroundContext)
                    item.id = UUID()
                    item.createdAt = Date()
                    item.name = dish
                    item.normalizedName = normalized
                    item.source = "preset"
                    item.carbs = preset.carbs
                    item.fat = preset.fat
                    item.protein = preset.protein
                    item.useCount = 0
                    imported += 1
                }

                if self.backgroundContext.hasChanges {
                    try self.backgroundContext.save()
                }
                return imported
            }
        } catch {
            debug(.service, "\(DebuggingIdentifiers.failed) Food library preset import failed: \(error)")
            return 0
        }
    }
}
