import Combine
import CoreData
import SwiftUI

extension TherapyRatioCalculator {
    /// The source of the total daily dose (TDD) estimate driving the recommendations.
    enum TDDSource: String, CaseIterable, Identifiable {
        case pumpHistory
        case bodyWeight

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .pumpHistory:
                return String(localized: "Insulin History", comment: "TDD source: pump insulin history")
            case .bodyWeight:
                return String(localized: "Body Weight", comment: "TDD source: body weight estimate")
            }
        }
    }

    final class StateModel: BaseStateModel<Provider> {
        @Injected() private var nightscout: NightscoutManager!
        @Injected() private var tidepoolManager: TidepoolManager!
        @Injected() private var broadcaster: Broadcaster!

        /// Average of trailing-24h insulin totals sampled over the last 7 days, weighted equally per day
        @Published var averageTDD: Decimal?
        /// Number of distinct days contributing TDD samples
        @Published var tddSampleDays: Int = 0
        /// Hours between the oldest and newest usable TDD sample
        @Published var tddSpanHours: Double = 0
        @Published var tddSource: TDDSource = .pumpHistory
        @Published var bodyWeightKg: Decimal = 0
        @Published var currentSensitivities: [InsulinSensitivityEntry] = []
        @Published var currentCarbRatioSchedule: [CarbRatioEntry] = []
        @Published var isLoadingTDD = true

        private(set) var units: GlucoseUnits = .mgdL

        private let context = CoreDataStack.shared.newTaskContext()

        /// New adult pumpers typically need ~0.4-0.6 U/kg/day total insulin; use the middle as a starting estimate.
        static let unitsPerKg: Decimal = 0.5
        /// Clinical "1800 rule" for rapid-acting insulin: ISF (mg/dL per U) = 1800 / TDD.
        static let isfRuleNumerator: Decimal = 1800
        /// Clinical "500 rule": carb ratio (g per U) = 500 / TDD.
        static let carbRatioRuleNumerator: Decimal = 500
        /// Recommendations require this many distinct days of insulin history.
        static let minimumSampleDays = 3

        override func subscribe() {
            units = settingsManager.settings.units
            // Stored profiles are per pumped unit; this screen displays and
            // recommends values per unit of actual insulin, like the editors.
            currentSensitivities = provider.isfProfile.sensitivities.map(realSensitivity)
            currentCarbRatioSchedule = provider.carbRatios.schedule.map(realCarbRatio)

            Task {
                await self.loadTDDHistory()
            }
        }

        var hasSufficientHistory: Bool {
            // Require a real multi-day span, not just touched calendar days — ~26 hours of
            // data crossing two midnights would otherwise count as "3 days".
            averageTDD != nil && tddSampleDays >= Self.minimumSampleDays &&
                tddSpanHours >= Double(Self.minimumSampleDays - 1) * 24.0
        }

        /// Concentration factor, or 1 before the resolver injects services —
        /// SwiftUI evaluates `body` (which reads the values below) first.
        private var concentrationFactor: Decimal {
            settingsManager?.settings.insulinConcentrationFactorDecimal ?? 1
        }

        /// Whether diluted insulin is in use, so the screen can explain that
        /// Trio's other TDD figures are shown in larger pumped units.
        var isDiluted: Bool { concentrationFactor != 1 }

        /// The recorded 7-day average TDD in *actual insulin* units — the unit
        /// every ISF, CR, and rule on this screen speaks. Storage is in pumped
        /// volume units.
        var averageRealTDD: Decimal? {
            averageTDD.map { $0 * concentrationFactor }
        }

        /// The TDD driving the recommendations in *actual insulin* units, per the
        /// selected source — the clinical 1800/500 rules are defined for actual
        /// insulin. Insufficient history still yields a preliminary estimate — it
        /// only blocks applying. Pump history is recorded in pumped volume units;
        /// the body-weight estimate is inherently actual insulin.
        var effectiveRealTDD: Decimal? {
            switch tddSource {
            case .pumpHistory:
                return averageRealTDD
            case .bodyWeight:
                guard bodyWeightKg > 0 else { return nil }
                return bodyWeightKg * Self.unitsPerKg
            }
        }

        /// The same TDD in pumped volume units, matching the figures Trio shows
        /// everywhere else (Home, statistics, uploads).
        var effectiveTDD: Decimal? {
            effectiveRealTDD.map { $0 / concentrationFactor }
        }

        /// Whether the current recommendations may be written to the profile.
        /// Preliminary pump-history estimates (fewer than 3 full days) are view-only.
        var canApplyRecommendations: Bool {
            switch tddSource {
            case .pumpHistory:
                return hasSufficientHistory
            case .bodyWeight:
                return bodyWeightKg > 0
            }
        }

        /// Recommended ISF in mg/dL per unit of *actual insulin* (the unit the
        /// ISF editor displays), clamped to the ISF editor's bounds.
        var recommendedISF: Decimal? {
            guard let tdd = effectiveRealTDD, tdd > 0 else { return nil }
            let isf = Self.isfRuleNumerator / tdd
            return Self.clamp(Self.round(isf, scale: 0), min: 9, max: 7200)
        }

        /// Recommended carb ratio in grams per unit of *actual insulin* (the unit
        /// the carb ratio editor displays), clamped to the carb ratio editor's bounds.
        var recommendedCarbRatio: Decimal? {
            guard let tdd = effectiveRealTDD, tdd > 0 else { return nil }
            let ratio = Self.carbRatioRuleNumerator / tdd
            // The editor grid is 0.1 g steps up to 50 g/U, whole grams above
            let rounded = ratio > 50 ? Self.round(ratio, scale: 0) : Self.round(ratio, scale: 1)
            return Self.clamp(rounded, min: 1, max: 2000)
        }

        @MainActor func loadTDDHistory() async {
            isLoadingTDD = true
            defer { isLoadingTDD = false }

            do {
                let sevenDaysAgo = Date().addingTimeInterval(-7 * 24 * 60 * 60)
                let results = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: TDDStored.self,
                    onContext: context,
                    predicate: NSPredicate(format: "date >= %@", sevenDaysAgo as NSDate),
                    key: "date",
                    ascending: false,
                    propertiesToFetch: ["total", "date"]
                )

                // The oldest TDD row overall approximates when Trio started recording;
                // trailing-24h totals taken within the first day after that undercount
                // the real daily dose and would skew the recommendations high.
                let firstEverResults = try await CoreDataStack.shared.fetchEntitiesAsync(
                    ofType: TDDStored.self,
                    onContext: context,
                    predicate: NSPredicate(value: true),
                    key: "date",
                    ascending: true,
                    fetchLimit: 1,
                    propertiesToFetch: ["date"]
                )

                let samples: [(date: Date, total: Decimal)] = await context.perform {
                    guard let rows = results as? [[String: Any]] else { return [] }

                    let firstEverDate = (firstEverResults as? [[String: Any]])?.first?["date"] as? Date
                    let rampUpCutoff = firstEverDate.map { $0.addingTimeInterval(24 * 60 * 60) }

                    return rows.compactMap { row in
                        guard let date = row["date"] as? Date,
                              let total = (row["total"] as? NSDecimalNumber)?.decimalValue,
                              total > 0
                        else { return nil }
                        if let rampUpCutoff, date < rampUpCutoff { return nil }
                        return (date, total)
                    }
                }

                if let oldest = samples.map(\.date).min(), let newest = samples.map(\.date).max() {
                    tddSpanHours = newest.timeIntervalSince(oldest) / 3600
                } else {
                    tddSpanHours = 0
                }

                // Each sample is a trailing-24h total; average per calendar day first so
                // days with more loop cycles do not dominate the overall average.
                let calendar = Calendar.current
                let samplesByDay = Dictionary(grouping: samples) { calendar.startOfDay(for: $0.date) }
                let dailyAverages = samplesByDay.values.map { daySamples -> Decimal in
                    daySamples.map(\.total).reduce(0, +) / Decimal(daySamples.count)
                }

                tddSampleDays = dailyAverages.count
                if dailyAverages.isEmpty {
                    averageTDD = nil
                } else {
                    averageTDD = Self.round(
                        dailyAverages.reduce(0, +) / Decimal(dailyAverages.count),
                        scale: 1
                    )
                }
            } catch {
                debug(.default, "\(DebuggingIdentifiers.failed) Failed to fetch TDD history: \(error)")
                averageTDD = nil
                tddSampleDays = 0
                tddSpanHours = 0
            }
        }

        private func realSensitivity(_ entry: InsulinSensitivityEntry) -> InsulinSensitivityEntry {
            InsulinSensitivityEntry(
                sensitivity: settingsManager.settings.realInsulinRatio(fromVolume: entry.sensitivity),
                offset: entry.offset,
                start: entry.start
            )
        }

        private func realCarbRatio(_ entry: CarbRatioEntry) -> CarbRatioEntry {
            CarbRatioEntry(
                start: entry.start,
                offset: entry.offset,
                ratio: settingsManager.settings.realInsulinRatio(fromVolume: entry.ratio)
            )
        }

        /// Replaces the entire ISF schedule with a single full-day entry at the recommended value.
        func applyRecommendedISF() {
            guard canApplyRecommendations, let isf = recommendedISF else { return }

            // The recommendation is per actual insulin unit; store per pumped unit.
            let storedISF = settingsManager.settings.volumeInsulinRatio(fromReal: isf)
            let profile = InsulinSensitivities(
                units: .mgdL,
                userPreferredUnits: .mgdL,
                sensitivities: [InsulinSensitivityEntry(sensitivity: storedISF, offset: 0, start: "00:00:00")]
            )
            provider.saveISFProfile(profile)
            currentSensitivities = profile.sensitivities.map(realSensitivity)

            DispatchQueue.main.async {
                self.broadcaster.notify(InsulinSensitivitiesObserver.self, on: .main) {
                    $0.insulinSensitivitiesDidChange(profile)
                }
            }
            uploadProfiles()
        }

        /// Replaces the entire carb ratio schedule with a single full-day entry at the recommended value.
        func applyRecommendedCarbRatio() {
            guard canApplyRecommendations, let ratio = recommendedCarbRatio else { return }

            // The recommendation is per actual insulin unit; store per pumped unit.
            let storedRatio = settingsManager.settings.volumeInsulinRatio(fromReal: ratio)
            let profile = CarbRatios(
                units: .grams,
                schedule: [CarbRatioEntry(start: "00:00:00", offset: 0, ratio: storedRatio)]
            )
            provider.saveCarbRatios(profile)
            currentCarbRatioSchedule = profile.schedule.map(realCarbRatio)

            DispatchQueue.main.async {
                self.broadcaster.notify(CarbRatiosObserver.self, on: .main) {
                    $0.carbRatiosDidChange(profile)
                }
            }
            uploadProfiles()
        }

        private func uploadProfiles() {
            Task.detached(priority: .low) {
                do {
                    debug(.nightscout, "Attempting to upload therapy profiles to Nightscout")
                    try await self.nightscout.uploadProfiles()
                } catch {
                    debug(
                        .default,
                        "\(DebuggingIdentifiers.failed) Failed to upload therapy profiles to Nightscout: \(error)"
                    )
                }
            }

            Task.detached(priority: .low) {
                await self.tidepoolManager.uploadSettings()
            }
        }

        private static func round(_ value: Decimal, scale: Int) -> Decimal {
            var result = Decimal()
            var input = value
            NSDecimalRound(&result, &input, scale, .plain)
            return result
        }

        private static func clamp(_ value: Decimal, min minValue: Decimal, max maxValue: Decimal) -> Decimal {
            min(max(value, minValue), maxValue)
        }
    }
}
