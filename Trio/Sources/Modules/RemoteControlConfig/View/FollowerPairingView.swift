import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sheet shown while pairing a new follower app. Renders the pairing bundle as
/// a QR code together with the verification code the follower must display
/// after scanning.
struct FollowerPairingView: View {
    let follower: PairedFollower
    let payload: String
    let onDone: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Scan this code with the Trio Follower app on the follower's phone.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let qrImage = Self.qrCodeImage(for: payload) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 280)
                            .padding(12)
                            .background(Color.white)
                            .cornerRadius(12)
                    } else {
                        Text("Failed to generate the QR code.")
                            .foregroundColor(.red)
                    }

                    VStack(spacing: 6) {
                        Text("Verification code")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text(follower.verificationCode)
                            .font(.system(.largeTitle, design: .monospaced).bold())
                            .kerning(4)
                        Text("After scanning, the follower app shows a verification code. Only confirm the pairing on the follower if it matches this one.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    Label(
                        "This QR code contains the follower's secret key. Do not screenshot or share it. Anyone who scans it can send commands to this Trio.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Pair \(follower.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    static func qrCodeImage(for string: String) -> UIImage? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // The pairing payload is large (~1.5 kB); low error correction keeps
        // the module count scannable.
        filter.correctionLevel = "L"

        guard let outputImage = filter.outputImage else { return nil }
        let scaled = outputImage.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
