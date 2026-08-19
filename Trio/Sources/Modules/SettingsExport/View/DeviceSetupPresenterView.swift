import SwiftUI

/// Sheet shown on the old device while setting up a new one: cycles through
/// the QR frames of the device-setup transfer so the new device can scan
/// them one after another, in any order.
struct DeviceSetupPresenterView: View {
    let frames: [String]
    let onDone: () -> Void

    @State private var currentFrame = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Fast enough that a full cycle of a typical transfer takes a few
    /// seconds, slow enough that each frame sits on screen for several
    /// camera frames.
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("On the new phone, open Trio and go to Settings → Export & Import Settings → Scan Setup Code, then point its camera at this screen until all parts are received.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if let qrImage = FollowerPairingView.qrCodeImage(for: frames[currentFrame]) {
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

                    Text("Part \(currentFrame + 1) of \(frames.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()

                    Label(
                        "These codes contain everything about this Trio — including all follower secrets and push keys. Do not screenshot, record or share them.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .padding(.horizontal)

                    Text("The codes repeat until every part has been scanned; the order does not matter. Keep both phones still and close together.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("Set Up New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
        .onReceive(timer) { _ in
            guard scenePhase == .active, frames.count > 1 else { return }
            currentFrame = (currentFrame + 1) % frames.count
        }
    }
}
