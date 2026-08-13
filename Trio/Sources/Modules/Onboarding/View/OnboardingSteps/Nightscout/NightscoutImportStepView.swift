import SwiftUI

struct NightscoutImportStepView: View {
    @Bindable var state: Onboarding.StateModel
    @State private var activeImportError: NightscoutImportError?

    var body: some View {
        ZStack {
            if state.nightscoutImportStatus == .running {
                VStack(alignment: .center) {
                    Spacer(minLength: 150)
                    CustomProgressView(
                        text: String(
                            localized: "Importing Settings...",
                            comment: "Progress text when importing settings via Nightscout"
                        )
                    )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    Text(
                        "Please choose if you want to import existing therapy settings from Nightscout or start from scratch."
                    )
                    .font(.headline)
                    .padding(.horizontal)
                    .multilineTextAlignment(.leading)

                    ForEach([NightscoutImportOption.useImport, NightscoutImportOption.skipImport], id: \.self) { option in
                        Button(action: {
                            state.nightscoutImportOption = option
                        }) {
                            HStack {
                                Image(systemName: state.nightscoutImportOption == option ? "largecircle.fill.circle" : "circle")
                                    .foregroundColor(state.nightscoutImportOption == option ? .accentColor : .secondary)
                                    .imageScale(.large)

                                Text(option.displayName)
                                    .foregroundColor(.primary)

                                Spacer()
                            }
                            .padding()
                            .background(Color.chart.opacity(0.65))
                            .cornerRadius(10)
                        }
                        .buttonStyle(.plain)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Trio will import the following therapy settings from your Nightscout instance:")
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        VStack(alignment: .leading) {
                            BulletPoint(String(localized: "Glucose Targets"))
                            BulletPoint(String(localized: "Basal Rates"))
                            BulletPoint(String(localized: "Carb Ratios"))
                            BulletPoint(
                                String(localized: "Insulin Sensitivities")
                            )
                        }
                    }
                    .padding(.horizontal)
                    .font(.footnote)
                    .foregroundStyle(Color.secondary)
                    .multilineTextAlignment(.leading)

                    // Trio uploads profiles in pumped units, so a profile it
                    // wrote round-trips exactly. A profile authored anywhere
                    // else — the usual reason to import one — is in actual
                    // insulin, and reading it as pumped units silently divides
                    // the whole therapy by the concentration factor.
                    if state.isDilutionEnabled {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(Color.orange)
                            Text(
                                "You use diluted insulin. Trio reads a Nightscout profile as **pumped units**, which is correct only for a profile Trio itself uploaded. If this profile was written by your care team or another app, its values are in actual insulin and the imported settings will be wrong by the dilution factor — check every value on the next steps before continuing."
                            )
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding()
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(10)
                        .padding(.horizontal)
                        .font(.footnote)
                        .multilineTextAlignment(.leading)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert(item: $activeImportError) { error in
            Alert(
                title: Text("Import Failed"),
                message: Text(
                    error
                        .message + "\n\n" +
                        String(localized: "Try again in a moment, or configure your Therapy Settings manually instead.")
                ),
                dismissButton: .default(Text("OK"))
            )
        }
        .onChange(of: state.nightscoutImportStatus) { _, newStatus in
            if newStatus == .failed {
                activeImportError = state.nightscoutImportError
            }
        }
    }
}
