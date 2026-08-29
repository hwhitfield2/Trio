import CoreData
import Foundation

/// Support for diluted insulin (e.g. U-10: 1 part U-100 insulin + 9 parts
/// diluent, so a 300 U reservoir holds 30 U of actual insulin).
///
/// Trio runs entirely in *pumped volume units*: every stored and runtime
/// insulin quantity — basal profiles, ISF, CR, boluses, SMBs, IOB, TDD,
/// delivery limits and caps, oref inputs and outputs, pump history, and the
/// HealthKit/Nightscout/Tidepool uploads — is denominated in units of fluid
/// the pump meters. Every number on screen therefore matches the pump's own
/// screens 1:1 and the loop's math needs no conversion anywhere: oref is
/// unit-agnostic as long as all quantities share one unit.
///
/// Therapy settings are shown, entered and stored in those same pumped volume
/// units, so a basal rate on screen is the rate the pump is programmed with and
/// nothing in the app needs converting. Because a prescription is written in
/// *actual* insulin, the editors carry that figure as a caption under each
/// value (`actualInsulinCaption`):
///
/// - Amounts and rates (basal rates, Max Bolus, Max Basal, Max IOB, delivery
///   caps): caption real = shown volume × factor.
/// - Per-unit ratios (ISF, carb ratio): caption real = shown volume ÷ factor.
///
/// When the concentration setting changes, the stored (volume-unit) therapy
/// settings are rescaled in place so their *real* meaning is preserved, and
/// the pump is re-programmed (basal schedule, delivery limits). Nothing else
/// in the app reads the concentration.
enum InsulinConcentrationOption: Int, CaseIterable, Identifiable {
    case u100 = 100
    case u50 = 50
    case u20 = 20
    case u10 = 10
    // Declaration order is display order: the concentration picker renders
    // allCases descending, so u5 stays last.
    case u5 = 5

    var id: Int { rawValue }

    /// Fraction of insulin in the reservoir fluid (1 = U-100, 0.1 = U-10).
    var factor: Decimal {
        Decimal(rawValue) / 100
    }

    var displayName: String {
        "U-\(rawValue)"
    }

    /// Mixing instructions relative to standard U-100 insulin.
    var dilutionRecipe: String? {
        switch self {
        case .u100:
            return nil
        case .u50:
            return String(localized: "1 part U-100 insulin + 1 part diluent")
        case .u20:
            return String(localized: "1 part U-100 insulin + 4 parts diluent")
        case .u10:
            return String(localized: "1 part U-100 insulin + 9 parts diluent")
        case .u5:
            return String(localized: "1 part U-100 insulin + 19 parts diluent")
        }
    }

    init(factor: Decimal) {
        self = Self.allCases.first(where: { $0.factor == factor }) ?? .u100
    }
}

extension TrioSettings {
    /// Fraction of insulin in the reservoir fluid: 1 = U-100 (standard),
    /// 0.1 = U-10. Falls back to 1 unless dilution is explicitly enabled and
    /// the stored concentration is a sane value.
    var insulinConcentrationFactorDecimal: Decimal {
        guard allowDilution, insulinConcentration > 0, insulinConcentration <= 1 else { return 1 }
        return insulinConcentration
    }

    var insulinConcentrationFactor: Double {
        Double(truncating: insulinConcentrationFactorDecimal as NSNumber)
    }

    /// A stored pump-volume amount or rate (bolus, basal U/hr, IOB) as actual
    /// insulin, for display in the therapy-settings editors.
    func realInsulinAmount(fromVolume volume: Decimal) -> Decimal {
        volume * insulinConcentrationFactorDecimal
    }

    /// An actual-insulin amount or rate entered in a settings editor as the
    /// pump-volume value Trio stores and the pump runs.
    func volumeInsulinAmount(fromReal real: Decimal) -> Decimal {
        real / insulinConcentrationFactorDecimal
    }

    /// A stored per-pumped-unit ratio (ISF mg/dL per U, CR g per U) as its
    /// per-actual-unit equivalent, for display in the therapy-settings editors.
    func realInsulinRatio(fromVolume volume: Decimal) -> Decimal {
        volume / insulinConcentrationFactorDecimal
    }

    /// A per-actual-unit ratio entered in a settings editor as the
    /// per-pumped-unit value Trio stores and the loop uses.
    func volumeInsulinRatio(fromReal real: Decimal) -> Decimal {
        real * insulinConcentrationFactorDecimal
    }

    /// Names the actual insulin a stored (pumped-volume) therapy value carries.
    ///
    /// Every number Trio shows — therapy settings included — is the volume of
    /// fluid the pump meters, so every screen matches the pump 1:1. Under
    /// dilution that volume is 2-20x the insulin in it, and a prescription is
    /// written in actual insulin: a care team's ISF of 500 typed into a field
    /// that wants 25 is a 20x under-correction. This caption is what carries
    /// the prescription figure alongside the pumped one. Returns nil at U-100,
    /// where the two coincide and the note would be noise.
    func actualInsulinCaption(forVolumeAmount volume: Decimal, unit: String) -> String? {
        guard insulinConcentrationFactorDecimal != 1 else { return nil }
        let real = realInsulinAmount(fromVolume: volume)
        return String(localized: "\(Self.captionNumber(real)) \(unit) actual insulin")
    }

    /// The ratio counterpart: ISF and carb ratio are *per unit*, so the actual
    /// insulin figure is larger, not smaller.
    func actualInsulinCaption(forVolumeRatio volume: Decimal, unit: String) -> String? {
        guard insulinConcentrationFactorDecimal != 1 else { return nil }
        let real = realInsulinRatio(fromVolume: volume)
        return String(localized: "\(Self.captionNumber(real)) \(unit) per unit of actual insulin")
    }

    /// Trims a converted value to something readable — the conversion can push
    /// a tidy entry to several decimals that carry no meaning here. Five places:
    /// the finest real quantum any supported pump/concentration pair produces is
    /// 0.00125 U/hr (a 0.025 U/hr Medtronic increment at U-5).
    private static func captionNumber(_ value: Decimal) -> String {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 5, .plain)
        return rounded.description
    }
}

extension PickerSetting {
    /// Widens the range so `value` is reachable, moving the bounds in whole
    /// steps only.
    ///
    /// `PickerSettingsProvider.generatePickerValues` builds the wheel by
    /// stepping up from `min`, so lowering `min` by an arbitrary amount shifts
    /// the entire stride and makes every ordinary round value (1.0, 1.5, …)
    /// disappear. Extending in whole steps keeps the grid aligned to where it
    /// started, which is what a value preserved across a concentration change
    /// needs.
    func extended(toCover value: Decimal) -> PickerSetting {
        guard step > 0 else { return self }
        var setting = self
        if value < setting.min {
            let deficit = setting.min - value
            setting.min -= wholeSteps(covering: deficit) * step
        }
        if value > setting.max {
            let excess = value - setting.max
            setting.max += wholeSteps(covering: excess) * step
        }
        return setting
    }

    private func wholeSteps(covering distance: Decimal) -> Decimal {
        var steps = distance / step
        var rounded = Decimal()
        NSDecimalRound(&rounded, &steps, 0, .up)
        return rounded
    }
}

/// One recorded concentration switch: at `date`, every insulin quantity
/// recorded *before* it must be multiplied by `amountScale` to read in the
/// volume units in force afterwards.
struct InsulinConcentrationChange: JSON, Equatable {
    var date: Date
    var amountScale: Decimal
}

/// The record of past concentration switches, used to re-express pump history
/// recorded under an earlier concentration.
///
/// Therapy *settings* are rescaled in place when the concentration changes, but
/// pump history deliberately is not: it is the log of what the pump actually
/// metered, and it must keep matching the pump's own screens, Nightscout, and
/// Apple Health. That leaves every history-derived quantity — IOB, COB from
/// bolus history, TDD, autotune — mixing two volume scales for as long as
/// pre-switch events stay in the window.
///
/// This ledger closes that gap at the *computation* boundary only: history is
/// stored and displayed exactly as recorded, and normalised on the way into the
/// loop. `scale(forEventAt:)` returns the product of every switch that happened
/// after an event, so several switches inside one window compose correctly.
enum InsulinConcentrationLedger {
    /// Longest history any consumer looks back over (autotune reaches ~30 days);
    /// older entries can never apply and are pruned on write.
    static let retention: TimeInterval = 45 * 24 * 60 * 60

    static func load(from storage: FileStorage) -> [InsulinConcentrationChange] {
        storage.retrieve(OpenAPS.Settings.insulinConcentrationHistory, as: [InsulinConcentrationChange].self) ?? []
    }

    static func loadAsync(from storage: FileStorage) async -> [InsulinConcentrationChange] {
        await storage.retrieveAsync(OpenAPS.Settings.insulinConcentrationHistory, as: [InsulinConcentrationChange].self) ?? []
    }

    /// Appends a switch. Identity rescales are not recorded — they would only
    /// add no-op entries that later multiply to 1 anyway.
    static func record(_ rescale: InsulinConcentrationRescale, at date: Date = Date(), in storage: FileStorage) {
        guard !rescale.isIdentity else { return }
        let cutoff = date.addingTimeInterval(-retention)
        var entries = load(from: storage).filter { $0.date >= cutoff }
        entries.append(InsulinConcentrationChange(date: date, amountScale: rescale.amountScale))
        storage.save(entries.sorted { $0.date < $1.date }, as: OpenAPS.Settings.insulinConcentrationHistory)
    }
}

extension Array where Element == InsulinConcentrationChange {
    /// Multiplier that carries an insulin amount recorded at `date` into the
    /// volume units currently in force. 1 when no switch has happened since.
    func scale(forEventAt date: Date) -> Decimal {
        reduce(Decimal(1)) { product, change in
            change.date > date ? product * change.amountScale : product
        }
    }

    /// True when no recorded switch would change any amount, so callers can skip
    /// walking their history entirely — the case for every user who has never
    /// touched the concentration setting, which is nearly all of them.
    var isEmptyOrIdentity: Bool {
        isEmpty || allSatisfy { $0.amountScale == 1 }
    }
}

/// Scale factors that re-express stored volume-unit therapy settings for a new
/// concentration while preserving their real-insulin meaning.
struct InsulinConcentrationRescale {
    /// Multiplier for amounts and rates (basal, max bolus/basal, max IOB, caps).
    let amountScale: Decimal
    /// Multiplier for per-unit ratios (ISF, carb ratio).
    let ratioScale: Decimal

    init(from oldFactor: Decimal, to newFactor: Decimal) {
        amountScale = oldFactor / newFactor
        ratioScale = newFactor / oldFactor
    }

    var isIdentity: Bool {
        amountScale == 1
    }

    /// Multiplies every stored TDD record by the amount scale so insulin
    /// history spanning a concentration switch stays in one consistent volume
    /// unit — TDD feeds dynamic ISF and the ISF/CR calculator for up to 10
    /// days. Returns a user-facing warning string on failure, nil on success.
    func rescaleTDDHistory() async -> String? {
        guard !isIdentity else { return nil }
        let context = CoreDataStack.shared.newTaskContext()
        let scale = amountScale as NSDecimalNumber
        return await context.perform {
            do {
                // TDDStored is never purged and grows by ~288 rows a day, so a
                // multi-year store holds six figures of rows. Walk it in
                // batches, saving and resetting as we go, rather than
                // materializing every row and committing one huge transaction.
                let request = TDDStored.fetchRequest()
                request.fetchBatchSize = 500
                let records = try context.fetch(request)
                for (index, record) in records.enumerated() {
                    autoreleasepool {
                        record.total = record.total?.multiplying(by: scale)
                        record.bolus = record.bolus?.multiplying(by: scale)
                        record.tempBasal = record.tempBasal?.multiplying(by: scale)
                        record.scheduledBasal = record.scheduledBasal?.multiplying(by: scale)
                        record.weightedAverage = record.weightedAverage?.multiplying(by: scale)
                    }
                    // Commit periodically so one multi-year transaction cannot
                    // stall or fail wholesale. The context is deliberately NOT
                    // reset here — that would invalidate the rows still to come.
                    if index % 500 == 499, context.hasChanges {
                        try context.save()
                    }
                }
                if context.hasChanges {
                    try context.save()
                }
                return nil
            } catch {
                return String(
                    localized: "Rescaling stored TDD statistics failed: \(error.localizedDescription). Insulin-history-based recommendations may be skewed for up to 10 days."
                )
            }
        }
    }
}
