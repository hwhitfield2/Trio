import SwiftUI

/// Names the unit a therapy-settings screen is working in when diluted insulin
/// is configured.
///
/// Every "U" in Trio — therapy settings included — is a *pumped volume*, so
/// every screen matches the pump's own. At U-100 that is also the actual
/// insulin and nothing needs saying. Under dilution the two differ by the
/// concentration factor, and a prescription is written in actual insulin: a
/// care team's ISF of 500 typed into a field that wants 25 is a 20x
/// under-correction. This banner names the unit before that happens; the
/// per-value captions carry the actual-insulin figure.
///
/// Renders nothing when dilution is off.
struct DilutionUnitBanner: View {
    /// What this screen's values are, e.g. "basal rates" or "Max IOB".
    let subject: String
    let settings: TrioSettings?

    private var concentrationName: String? {
        guard let settings, settings.insulinConcentrationFactorDecimal != 1 else { return nil }
        return InsulinConcentrationOption(factor: settings.insulinConcentrationFactorDecimal).displayName
    }

    var body: some View {
        if let concentrationName {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "drop.fill")
                    .foregroundStyle(Color.accentColor)
                Text(
                    "Diluted insulin (\(concentrationName)) is on: \(subject) here are in **pumped units**, matching the pump's own screens and everything Trio delivers. The actual insulin each value carries is shown beneath it."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding()
            .background(Color.chart.opacity(0.65))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .padding(.horizontal)
            .padding(.top)
        }
    }
}
