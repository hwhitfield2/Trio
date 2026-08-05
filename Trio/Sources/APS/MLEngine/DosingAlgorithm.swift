import Foundation

/// Seam between the loop pipeline and whichever algorithm decides doses
/// (docs/ML_DOSING_REPLACEMENT_PLAN.md §4, Phase 1/3).
///
/// Both the existing oref path and the future ML engine conform, and both emit
/// the same `Determination` shape — so persistence (`OrefDetermination` +
/// `Forecast`), charts, Nightscout, Live Activity, and the watch app work
/// unchanged whichever algorithm is active. The eventual selection order is:
///
///   settings toggle → ml | ml-shadow | oref (default oref)
///   fallback ladder → ml unhealthy ⇒ oref ⇒ zero-temp (plan §2.7, not toggleable)
///
/// Shadow mode runs both conformers each cycle and doses from oref while both
/// results are audited side by side.
protocol DosingAlgorithm {
    /// Stable identifier stamped into every DecisionAuditRecord ("oref", "ml").
    var identifier: String { get }

    /// Run one dosing decision for the cycle triggered by a newly delivered CGM value.
    func determine(
        currentTemp: TempBasal,
        shouldSmoothGlucose: Bool,
        clock: Date
    ) async throws -> Determination?
}

/// The existing oref (OpenAPS-JS) pipeline, wrapped unchanged.
final class OrefAlgorithm: DosingAlgorithm {
    let identifier = "oref"

    private let openAPS: OpenAPS

    init(openAPS: OpenAPS) {
        self.openAPS = openAPS
    }

    func determine(
        currentTemp: TempBasal,
        shouldSmoothGlucose: Bool,
        clock: Date
    ) async throws -> Determination? {
        try await openAPS.determineBasal(
            currentTemp: currentTemp,
            shouldSmoothGlucose: shouldSmoothGlucose,
            clock: clock
        )
    }
}
