import SwiftUI

/// Sheet shown on the old device while setting up a new one. By default it
/// presents the whole transfer as ONE static dense matrix — the new device
/// reads it across many camera frames, so nothing has to animate or be
/// scanned in parts. The looping QR frame sequence remains available as a
/// fallback for older Trio builds (and for the rare configuration too large
/// for a single matrix).
struct DeviceSetupPresenterView: View {
    let code: SettingsExport.StateModel.DeviceSetupCode
    let onDone: () -> Void

    @State private var showQRFrames = false
    @State private var currentFrame = 0
    @Environment(\.scenePhase) private var scenePhase

    /// Fast enough that a full cycle of a typical transfer takes a few
    /// seconds, slow enough that each frame sits on screen for several
    /// camera frames.
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    private var showingMatrix: Bool { code.matrixImage != nil && !showQRFrames }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    Text("On the new phone, open Trio and choose Set Up From Another Device (or Settings → Export & Import Settings → Scan Setup Code), then point its camera at this screen.")
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    if showingMatrix, let matrixImage = code.matrixImage {
                        Image(uiImage: matrixImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 340, maxHeight: 340)
                            .padding(10)
                            .background(Color.white)
                            .cornerRadius(12)

                        Text("Hold the phones steady about 15–25 cm apart; the new phone reads the code within a few seconds. Keep this screen at full brightness.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else if let qrImage = FollowerPairingView.qrCodeImage(for: code.frames[currentFrame]) {
                        Image(uiImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 280)
                            .padding(12)
                            .background(Color.white)
                            .cornerRadius(12)

                        Text("Part \(currentFrame + 1) of \(code.frames.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .monospacedDigit()

                        Text("The codes repeat until every part has been scanned; the order does not matter.")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    } else {
                        Text("Failed to generate the setup code.")
                            .foregroundColor(.red)
                    }

                    Label(
                        "This code contains everything about this Trio — including all follower secrets and push keys. Do not screenshot, record or share it.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .padding(.horizontal)

                    if code.matrixImage != nil {
                        Button(showQRFrames
                            ? String(localized: "Show as a single code")
                            : String(localized: "Trouble scanning? Show as QR codes")) {
                                showQRFrames.toggle()
                        }
                        .font(.footnote)
                    }
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
            guard !showingMatrix, scenePhase == .active, code.frames.count > 1 else { return }
            currentFrame = (currentFrame + 1) % code.frames.count
        }
    }
}
