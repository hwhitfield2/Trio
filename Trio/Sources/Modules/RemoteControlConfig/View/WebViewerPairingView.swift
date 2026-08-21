import AVFoundation
import SwiftUI
import UIKit

/// Sheet shown while pairing a read-only web viewer.
///
/// Two steps in one sitting: the browser scans this device's pairing code
/// (or the code is pasted into it), then this device scans the registration
/// code the browser displays back — that second scan is how the host learns
/// the browser's push subscription, since a viewer has no command channel to
/// register through.
struct WebViewerPairingView: View {
    let viewer: PairedFollower
    let payload: String
    @ObservedObject var state: RemoteControlConfig.StateModel
    let onDone: () -> Void

    @State private var isScanning = false
    @State private var isCopied = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    if state.viewerRegistered {
                        registeredContent
                    } else if isScanning {
                        scannerContent
                    } else {
                        pairingContent
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Pair \(viewer.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onDone)
                }
            }
        }
    }

    private var pairingContent: some View {
        VStack(spacing: 20) {
            Text("Open the Trio web viewer in the caregiver's browser and scan this code with it — or copy the code and paste it there.")
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let qrImage = FollowerPairingView.qrCodeImage(for: payload) {
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
                Text(viewer.verificationCode)
                    .font(.system(.largeTitle, design: .monospaced).bold())
                    .kerning(4)
                Text("After scanning, the browser shows a verification code. Only continue if it matches this one.")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button {
                UIPasteboard.general.string = payload
                isCopied = true
            } label: {
                Label("Copy Pairing Code", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .alert("Copied", isPresented: $isCopied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Paste the code into the web viewer's pairing screen, then delete it from wherever it passed through — it is a key, not a link.")
            }

            Label(
                "This code contains the viewer's secret key. Anyone who captures it can read glucose, insulin and carb data from this Trio until the viewer is revoked. It grants no control.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.footnote)
            .foregroundColor(.orange)
            .padding(.horizontal)

            Divider().padding(.horizontal)

            Text("When the browser shows its own code, scan it here to finish:")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button {
                state.viewerRegistrationError = nil
                isScanning = true
            } label: {
                Label("Scan Browser Code", systemImage: "camera.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .foregroundColor(.white)
            .padding(.horizontal)

            if let error = state.viewerRegistrationError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
    }

    private var scannerContent: some View {
        VStack(spacing: 16) {
            ViewerRegistrationScannerRepresentable { code in
                if state.handleScannedViewerRegistration(code) {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    isScanning = false
                }
            } onPermissionDenied: {
                isScanning = false
                state.viewerRegistrationError = String(
                    localized: "Trio needs camera access to scan the browser's code. Allow it in the iOS Settings app under Trio → Camera."
                )
            }
            .frame(height: 360)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal)

            Text("Point the camera at the code shown in the web viewer.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if let error = state.viewerRegistrationError {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.orange)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Button("Back") { isScanning = false }
                .buttonStyle(.bordered)
        }
    }

    private var registeredContent: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundColor(.green)
            Text("\(viewer.name) is connected")
                .font(.headline)
            Text("The browser receives its first data within moments and updates itself from now on. It can see glucose, insulin and carb data, and can never send commands to this Trio.")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .foregroundColor(.white)
        }
    }
}

/// Minimal QR-only camera for scanning the browser's registration code.
private struct ViewerRegistrationScannerRepresentable: UIViewControllerRepresentable {
    let onQRCode: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context _: Context) -> ViewerRegistrationScannerController {
        let controller = ViewerRegistrationScannerController()
        controller.onQRCode = onQRCode
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_: ViewerRegistrationScannerController, context _: Context) {}
}

final class ViewerRegistrationScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onQRCode: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "ViewerRegistrationScanner.session")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.configureSession()
                    } else {
                        self?.onPermissionDenied?()
                    }
                }
            }
        default:
            onPermissionDenied?()
        }
    }

    private func configureSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            let metadataOutput = AVCaptureMetadataOutput()
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                metadataOutput.metadataObjectTypes = [.qr]
            }

            session.commitConfiguration()
            session.startRunning()

            DispatchQueue.main.async {
                let layer = AVCaptureVideoPreviewLayer(session: self.session)
                layer.videoGravity = .resizeAspectFill
                layer.frame = self.view.bounds
                self.view.layer.addSublayer(layer)
                self.previewLayer = layer
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        sessionQueue.async { [weak self] in
            guard let self, session.isRunning else { return }
            session.stopRunning()
        }
    }

    func metadataOutput(
        _: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from _: AVCaptureConnection
    ) {
        for object in metadataObjects {
            guard let readable = object as? AVMetadataMachineReadableCodeObject,
                  readable.type == .qr,
                  let string = readable.stringValue
            else { continue }
            onQRCode?(string)
        }
    }
}
