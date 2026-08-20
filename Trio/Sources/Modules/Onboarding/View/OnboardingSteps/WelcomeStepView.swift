import SwiftUI

/// Welcome step view shown at the beginning of onboarding.
struct WelcomeStepView: View {
    /// Opens the device-setup scanner; nil hides the shortcut (previews).
    var onScanSetupCode: (() -> Void)?

    var body: some View {
        VStack(alignment: .center, spacing: 20) {
            PulsingLogoAnimation()

            Spacer(minLength: 10)

            VStack(alignment: .leading, spacing: 20) {
                Text("Hi there!")
                    .font(.title2)
                    .fontWeight(.bold)
                    .multilineTextAlignment(.center)

                Text(
                    "Welcome to Trio — an automated insulin delivery system for iOS based on the OpenAPS algorithm with adaptations."
                )
                .multilineTextAlignment(.leading)
                .foregroundColor(.secondary)

                Text(
                    "Trio is designed to help manage your diabetes efficiently. To get the most out of the app, we'll guide you through setting up some essential parameters."
                )
                .multilineTextAlignment(.leading)
                .foregroundColor(.secondary)

                Text("Let's go through a few quick steps to ensure Trio works optimally for you.")
                    .multilineTextAlignment(.leading)
                    .foregroundColor(.primary)
                    .bold()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)

            if let onScanSetupCode {
                VStack(spacing: 12) {
                    Text("Already running Trio on another phone?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Button(action: onScanSetupCode) {
                        Label("Set Up From Another Device", systemImage: "qrcode.viewfinder")
                            .padding(.vertical, 10)
                            .padding(.horizontal, 16)
                            .background(Capsule().stroke(Color.blue, lineWidth: 1.5))
                    }

                    Text(
                        "On the old phone, open Settings → Export & Import Settings → Show Setup Code, then scan it here to copy everything over and skip the guided setup."
                    )
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal)
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
    }
}
