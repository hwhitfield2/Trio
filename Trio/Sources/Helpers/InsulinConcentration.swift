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
/// The concentration setting exists only so therapy settings can be *entered
/// and read* in actual insulin units. The settings editors convert at the UI
/// boundary:
///
/// - Amounts and rates (basal rates, Max Bolus, Max Basal, Max IOB, delivery
///   caps): displayed real = stored volume × factor.
/// - Per-unit ratios (ISF, carb ratio): displayed real = stored volume ÷ factor.
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
}
