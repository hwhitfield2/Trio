import AVFoundation
import PhotosUI
import SwiftUI

/// Camera screen for photographing a meal with a scale-reference object.
///
/// The user picks a common object (soda can, credit card, fork, hand), places it
/// inside the dashed outline shown off to the side of the frame, and takes the photo.
/// A photo-library fallback is offered for photos taken earlier.
struct MealPhotoCaptureView: View {
    @Binding var selectedReference: ScaleReferenceObject
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = MealPhotoCameraModel()
    @State private var libraryItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()

                referenceOverlay
            } else {
                cameraDeniedView
            }

            VStack {
                topBar
                Spacer()
                bottomBar
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.capturedImage) { _, image in
            if let image = image {
                onCapture(image)
            }
        }
        .onChange(of: libraryItem) { _, item in
            guard let item = item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let image = UIImage(data: data)
                {
                    await MainActor.run { onCapture(image) }
                }
            }
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(.black.opacity(0.5), in: Circle())
            }

            Spacer()

            Menu {
                ForEach(ScaleReferenceObject.allCases) { reference in
                    Button {
                        selectedReference = reference
                    } label: {
                        Label(reference.displayName, systemImage: reference.iconName)
                    }
                }
            } label: {
                HStack {
                    Image(systemName: selectedReference.iconName)
                    Text(selectedReference.displayName)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(.black.opacity(0.5), in: Capsule())
            }
        }
        .padding()
    }

    private var bottomBar: some View {
        VStack(spacing: 16) {
            if selectedReference != ScaleReferenceObject.none {
                Text("Place the \(selectedReference.displayName.lowercased()) inside the outline, then take the photo.")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.5), in: Capsule())
            }

            HStack {
                PhotosPicker(selection: $libraryItem, matching: .images) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.title2)
                        .foregroundStyle(.white)
                        .padding(14)
                        .background(.black.opacity(0.5), in: Circle())
                }

                Spacer()

                Button {
                    camera.capturePhoto()
                } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                        Circle().fill(.white).frame(width: 62, height: 62)
                    }
                }
                .disabled(!camera.isAuthorized || camera.isCapturing)

                Spacer()

                // Symmetry spacer matching the library button footprint
                Color.clear.frame(width: 54, height: 54)
            }
            .padding(.horizontal, 28)
        }
        .padding(.bottom, 24)
    }

    /// Dashed outline in the lower-trailing area of the frame where the reference object belongs.
    private var referenceOverlay: some View {
        GeometryReader { geometry in
            if selectedReference != ScaleReferenceObject.none {
                let width = geometry.size.width * 0.24
                let height = width / selectedReference.overlayAspectRatio
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: 2.5, dash: [7, 5])
                    )
                    .foregroundStyle(.yellow)
                    .frame(width: width, height: min(height, geometry.size.height * 0.35))
                    .overlay(alignment: .top) {
                        Image(systemName: selectedReference.iconName)
                            .foregroundStyle(.yellow)
                            .padding(.top, 6)
                    }
                    .position(
                        x: geometry.size.width - width / 2 - 24,
                        y: geometry.size.height * 0.68
                    )
            }
        }
        .allowsHitTesting(false)
    }

    private var cameraDeniedView: some View {
        VStack(spacing: 12) {
            Image(systemName: "camera.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Camera access is required to photograph your meal.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .buttonStyle(.borderedProminent)
            Text("You can also choose an existing photo from your library below.")
                .font(.footnote)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 32)
    }
}

// MARK: - Camera session model

final class MealPhotoCameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate {
    @Published var isAuthorized = false
    @Published var isCapturing = false
    @Published var capturedImage: UIImage?

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let sessionQueue = DispatchQueue(label: "MealPhotoCameraModel.sessionQueue", qos: .userInitiated)
    private var isConfigured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.isAuthorized = granted
                    if granted {
                        self?.configureAndStart()
                    }
                }
            }
        default:
            isAuthorized = false
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    func capturePhoto() {
        isCapturing = true
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let settings = AVCapturePhotoSettings()
            self.photoOutput.capturePhoto(with: settings, delegate: self)
        }
    }

    private func configureAndStart() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            if !self.isConfigured {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                   let input = try? AVCaptureDeviceInput(device: device),
                   self.session.canAddInput(input)
                {
                    self.session.addInput(input)
                }

                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }

                self.session.commitConfiguration()
                self.isConfigured = true
            }

            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func photoOutput(
        _: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.isCapturing = false
            guard error == nil,
                  let data = photo.fileDataRepresentation(),
                  let image = UIImage(data: data)
            else {
                debug(.service, "Meal photo capture failed: \(String(describing: error))")
                return
            }
            self?.capturedImage = image
        }
    }
}

// MARK: - Camera preview layer

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

        var previewLayer: AVCaptureVideoPreviewLayer {
            layer as! AVCaptureVideoPreviewLayer
        }
    }

    func makeUIView(context _: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_: PreviewView, context _: Context) {}
}
