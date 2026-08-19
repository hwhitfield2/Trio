import AVFoundation
import SwiftUI

/// Sheet shown on the NEW device: scans the QR frame sequence presented by
/// the old device, shows collection progress, and hands the assembled
/// transfer back once every part has been seen.
struct DeviceSetupScannerView: View {
    let onTransfer: (DeviceSetupTransfer) -> Void
    let onCancel: () -> Void

    @State private var assembler = DeviceSetupScanAssembler()
    @State private var receivedCount = 0
    @State private var expectedCount: Int?
    @State private var scanError: String?
    @State private var finished = false
    @State private var cameraDenied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                if cameraDenied {
                    Spacer()
                    Label(
                        "Trio needs camera access to scan the setup code. Allow it in the iOS Settings app under Trio → Camera.",
                        systemImage: "camera.fill"
                    )
                    .multilineTextAlignment(.center)
                    .padding()
                    Spacer()
                } else {
                    QRCodeScannerRepresentable(
                        onCode: handleScannedCode,
                        onPermissionDenied: { cameraDenied = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        if let expectedCount {
                            ProgressView(value: Double(receivedCount), total: Double(expectedCount))
                                .padding(.horizontal)
                            Text("Received \(receivedCount) of \(expectedCount) parts")
                                .font(.callout)
                                .monospacedDigit()
                        } else {
                            Text("Point the camera at the setup code on the old device.")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }

                        if let scanError {
                            Text(scanError)
                                .font(.footnote)
                                .foregroundColor(.orange)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
                        }
                    }
                    .padding(.bottom)
                }
            }
            .navigationTitle("Scan Setup Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard !finished else { return }
        do {
            let isNew = try assembler.add(code)
            if isNew {
                receivedCount = assembler.receivedCount
                expectedCount = assembler.expectedCount
                scanError = nil
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            if assembler.isComplete {
                finished = true
                let transfer = try assembler.assemble()
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                onTransfer(transfer)
            }
        } catch let error as DeviceSetupCodecError {
            switch error {
            case .notASetupFrame:
                // The camera sees plenty of stray codes (and the follower
                // pairing QR); stay quiet rather than flashing warnings.
                break
            case .mismatchedTransfer:
                // The host was restarted with a fresh code — start over with
                // this frame rather than asking the user to notice and cancel.
                assembler = DeviceSetupScanAssembler()
                _ = try? assembler.add(code)
                receivedCount = assembler.receivedCount
                expectedCount = assembler.expectedCount
                scanError = String(localized: "The setup code changed — scanning restarted. Keep the camera on the old device's screen.")
            case .corruptPayload:
                finished = false
                assembler = DeviceSetupScanAssembler()
                receivedCount = 0
                expectedCount = nil
                scanError = error.localizedDescription
            default:
                scanError = error.localizedDescription
            }
        } catch {
            scanError = error.localizedDescription
        }
    }
}

/// Thin AVFoundation wrapper: camera preview plus QR metadata detection.
/// Every decoded QR string is reported; the caller decides what it means.
private struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    let onCode: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context _: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.onCode = onCode
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_: QRScannerViewController, context _: Context) {}
}

final class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "DeviceSetupScanner.session")
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

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                return
            }
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            output.metadataObjectTypes = [.qr]

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
            onCode?(string)
        }
    }
}
