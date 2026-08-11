import Foundation
import HealthKit
import LoopKit

/// Support for diluted insulin (e.g. U-10: 1 part U-100 insulin + 9 parts diluent).
///
/// Trio stores and computes every insulin quantity — boluses, basal rates, IOB,
/// TDD, delivery limits, the basal profile — in *actual* insulin units (U-100
/// equivalents). The pump, however, meters fluid volume and always believes it
/// is delivering U-100. With diluted insulin the pump must move
/// `1 / concentration` volume units to deliver one actual insulin unit, so all
/// conversions happen at the pump boundary and nowhere else:
///
/// - Commands sent to the pump (boluses, temp basal rates, delivery limits,
///   basal schedules) are divided by the concentration factor.
/// - Feedback read from the pump (history events, active temp basal state,
///   supported increments) is multiplied by the concentration factor.
///
/// Reservoir readings deliberately stay in volume units: they describe the
/// fluid physically present in the reservoir and match the pump's own UI and
/// low-reservoir alerts.
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
}

extension PumpSettings {
    /// The user's delivery limits (actual insulin units) expressed in pump
    /// volume units, ready to sync to the pump.
    func pumpDeliveryLimits(insulinConcentration factor: Double) -> DeliveryLimits {
        DeliveryLimits(
            maximumBasalRate: HKQuantity(
                unit: .internationalUnitsPerHour,
                doubleValue: Double(maxBasal) / factor
            ),
            maximumBolus: HKQuantity(
                unit: .internationalUnit(),
                doubleValue: Double(maxBolus) / factor
            )
        )
    }

    /// These settings with the limits the pump actually accepted (reported in
    /// volume units) converted back to actual insulin units.
    func applyingPumpReported(limits: DeliveryLimits, insulinConcentration factor: Double) -> PumpSettings {
        PumpSettings(
            insulinActionCurve: insulinActionCurve,
            maxBolus: limits.maximumBolus
                .map { Decimal($0.doubleValue(for: .internationalUnit()) * factor) } ?? maxBolus,
            maxBasal: limits.maximumBasalRate
                .map { Decimal($0.doubleValue(for: .internationalUnitsPerHour) * factor) } ?? maxBasal
        )
    }
}

extension PumpManager {
    /// Rounds actual insulin units to the nearest bolus volume the pump can
    /// deliver, expressed in actual insulin units again. With U-10 a pump that
    /// meters 0.05 U of volume can deliver increments of 0.005 U of insulin.
    func roundToSupportedBolusVolume(units: Double, insulinConcentration factor: Double) -> Double {
        roundToSupportedBolusVolume(units: units / factor) * factor
    }

    /// Rounds an actual-insulin basal rate to the nearest rate the pump can
    /// deliver, expressed in actual insulin units again.
    func roundToSupportedBasalRate(unitsPerHour: Double, insulinConcentration factor: Double) -> Double {
        roundToSupportedBasalRate(unitsPerHour: unitsPerHour / factor) * factor
    }
}
