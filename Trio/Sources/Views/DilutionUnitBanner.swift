import SwiftUI

/// Names the unit a therapy-settings screen is working in when diluted insulin
/// is configured.
///
/// Trio shows two different quantities under the same "U" label: therapy
/// settings are entered and read in *actual insulin*, while everything the pump
/// delivers — boluses, IOB, TDD, history, uploads — is shown in *pumped volume*
/// so it matches the pump's own screens. At U-100 those are the same number and
/// nothing needs saying. At U-10 they differ by 10x, and a user comparing a
/// Max IOB of 1 U against a home screen reading 3 U of IOB has every reason to
/// think something is wrong. This banner is what tells them it is not.
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
                    "Diluted insulin (\(concentrationName)) is on: \(subject) here are in units of **actual insulin**. Everything Trio delivers — boluses, IOB, and TDD — is shown in pumped units instead, matching the pump's own screens."
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
