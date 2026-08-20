import AVFoundation
import CoreImage
import SwiftUI
import Vision

/// Sheet shown on the NEW device: reads the single dense setup matrix from
/// the old device's screen, and still accepts the legacy QR frame sequence
/// from older Trio builds — both through the same camera session.
struct DeviceSetupScannerView: View {
    let onTransfer: (DeviceSetupTransfer) -> Void
    let onCancel: () -> Void

    // Legacy QR frame assembly
    @State private var assembler = DeviceSetupScanAssembler()
    @State private var receivedCount = 0
    @State private var expectedCount: Int?

    @State private var denseSymbolSeen = false
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
                    SetupCodeCameraRepresentable(
                        onDensePayload: handleDensePayload,
                        onDenseProgress: { denseSymbolSeen = true },
                        onQRCode: handleScannedQRCode,
                        onPermissionDenied: { cameraDenied = true }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal)

                    VStack(spacing: 8) {
                        if let expectedCount {
                            // Legacy QR sequence in progress.
                            ProgressView(value: Double(receivedCount), total: Double(expectedCount))
                                .padding(.horizontal)
                            Text("Received \(receivedCount) of \(expectedCount) parts")
                                .font(.callout)
                                .monospacedDigit()
                        } else if denseSymbolSeen {
                            Text("Reading the setup code — hold both phones steady…")
                                .font(.callout)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal)
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

    private func handleDensePayload(_ payload: Data) {
        guard !finished else { return }
        do {
            let transfer = try DeviceSetupPayloadCoder.decompress(payload)
            finished = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onTransfer(transfer)
        } catch {
            // The matrix's own hash already matched, so this is a version
            // mismatch or similar — worth telling the user about.
            scanError = error.localizedDescription
        }
    }

    private func handleScannedQRCode(_ code: String) {
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

/// Camera wrapper feeding both decoders: raw frames to the dense-matrix
/// processor and detected QR strings to the legacy assembler.
private struct SetupCodeCameraRepresentable: UIViewControllerRepresentable {
    let onDensePayload: (Data) -> Void
    let onDenseProgress: () -> Void
    let onQRCode: (String) -> Void
    let onPermissionDenied: () -> Void

    func makeUIViewController(context _: Context) -> SetupCodeCameraViewController {
        let controller = SetupCodeCameraViewController()
        controller.onDensePayload = onDensePayload
        controller.onDenseProgress = onDenseProgress
        controller.onQRCode = onQRCode
        controller.onPermissionDenied = onPermissionDenied
        return controller
    }

    func updateUIViewController(_: SetupCodeCameraViewController, context _: Context) {}
}

final class SetupCodeCameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate
{
    var onDensePayload: ((Data) -> Void)?
    var onDenseProgress: (() -> Void)?
    var onQRCode: ((String) -> Void)?
    var onPermissionDenied: (() -> Void)?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "DeviceSetupScanner.session")
    private let processingQueue = DispatchQueue(label: "DeviceSetupScanner.dense")
    private var previewLayer: AVCaptureVideoPreviewLayer?

    private let denseProcessor = DenseMatrixScanProcessor()
    private var isProcessingFrame = false
    private var frameCounter = 0
    private var payloadDelivered = false

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
            if session.canSetSessionPreset(.hd1920x1080) {
                session.sessionPreset = .hd1920x1080
            }

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input)
            else {
                session.commitConfiguration()
                return
            }
            session.addInput(input)

            // Legacy QR frames.
            let metadataOutput = AVCaptureMetadataOutput()
            if session.canAddOutput(metadataOutput) {
                session.addOutput(metadataOutput)
                metadataOutput.setMetadataObjectsDelegate(self, queue: .main)
                metadataOutput.metadataObjectTypes = [.qr]
            }

            // Dense matrix: raw frames.
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
                videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
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

    // MARK: - Legacy QR path

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

    // MARK: - Dense matrix path

    func captureOutput(
        _: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from _: AVCaptureConnection
    ) {
        guard !payloadDelivered, !isProcessingFrame else { return }
        // Every frame is another exposure of the same static symbol, but the
        // decode attempt dominates the cost — every other frame is plenty.
        frameCounter += 1
        guard frameCounter % 2 == 0 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        isProcessingFrame = true
        let result = denseProcessor.process(pixelBuffer: pixelBuffer)
        isProcessingFrame = false

        switch result {
        case .none:
            break
        case .symbolSeen:
            DispatchQueue.main.async { self.onDenseProgress?() }
        case let .payload(data):
            payloadDelivered = true
            DispatchQueue.main.async { self.onDensePayload?(data) }
        }
    }
}

/// Turns camera frames into dense-matrix decode attempts:
/// rectangle detection → perspective correction → frame-edge location →
/// per-cell sampling → vote accumulation → Reed-Solomon decode.
///
/// The symbol is static, so every frame is an independent noisy reading of
/// the same cells. Samples are folded into an exponential moving average per
/// cell; the average is what gets decoded, so cell errors from any single
/// blurry or glared frame wash out after a few frames.
final class DenseMatrixScanProcessor {
    enum Result {
        case none
        /// A plausible symbol is in view (frame located) but not decoded yet.
        case symbolSeen
        case payload(Data)
    }

    /// Side of the canonical working image the detected card is warped to.
    /// 1120 px across at most 281 modules still leaves ~4 px per module.
    private let workingSide = 1120

    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 3
        request.minimumConfidence = 0.6
        request.minimumAspectRatio = 0.7
        request.maximumAspectRatio = 1.0
        request.minimumSize = 0.2
        request.quadratureTolerance = 25
        return request
    }()

    /// Per-grid-size EMA of cell luminances, square symbol (interior grid).
    private var accumulators: [Int: [Float]] = [:]
    /// Per-grid-size EMA of cell luminances, orb symbol (full bounding grid).
    private var orbAccumulators: [Int: [Float]] = [:]
    /// Set once any header decodes for a size — later frames only try that one.
    private var lockedSize: Int?
    private var lockedShape: DenseMatrixCode.Shape?
    private var grayBuffer: [UInt8]

    init() {
        grayBuffer = [UInt8](repeating: 0, count: workingSide * workingSide)
    }

    func process(pixelBuffer: CVPixelBuffer) -> Result {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        guard (try? handler.perform([rectangleRequest])) != nil,
              let observations = rectangleRequest.results, !observations.isEmpty
        else { return .none }

        var seenSymbol = false
        for observation in observations.sorted(by: { $0.confidence > $1.confidence }) {
            guard let corrected = perspectiveCorrect(image, observation: observation) else { continue }
            renderGray(corrected)

            // The two symbol shapes have opposite polarity, so their locators
            // cannot false-positive on each other: the square frame is a dark
            // band on a light card, the orb ring a bright band on a dark one.
            if lockedShape != .orb, let frame = locateFrame() {
                seenSymbol = true
                if let payload = attemptDecode(frameBounds: frame) {
                    return .payload(payload)
                }
            }
            if lockedShape != .square, let ring = locateRing() {
                seenSymbol = true
                if let payload = attemptDecodeOrb(ringBounds: ring) {
                    return .payload(payload)
                }
            }
        }
        return seenSymbol ? .symbolSeen : .none
    }

    private func perspectiveCorrect(_ image: CIImage, observation: VNRectangleObservation) -> CIImage? {
        let extent = image.extent
        func point(_ p: CGPoint) -> CIVector {
            CIVector(x: extent.origin.x + p.x * extent.width, y: extent.origin.y + p.y * extent.height)
        }
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(point(observation.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(observation.topRight), forKey: "inputTopRight")
        filter.setValue(point(observation.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(observation.bottomRight), forKey: "inputBottomRight")
        return filter.outputImage
    }

    /// Renders the corrected quad into the fixed grayscale working buffer.
    private func renderGray(_ image: CIImage) {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return }
        let scaled = image
            .transformed(by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
            .transformed(by: CGAffineTransform(
                scaleX: CGFloat(workingSide) / extent.width,
                y: CGFloat(workingSide) / extent.height
            ))
        grayBuffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            ciContext.render(
                scaled,
                toBitmap: base,
                rowBytes: workingSide,
                bounds: CGRect(x: 0, y: 0, width: workingSide, height: workingSide),
                format: .L8,
                colorSpace: CGColorSpaceCreateDeviceGray()
            )
        }
    }

    private func luminance(x: Int, y: Int) -> Int {
        Int(grayBuffer[y * workingSide + x])
    }

    /// Locates the symbol's outer black frame in the working image by probing
    /// inward from each edge. Handles both detection outcomes: the rectangle
    /// was the white card around the symbol, or the symbol's frame itself.
    private func locateFrame() -> (left: Int, right: Int, top: Int, bottom: Int)? {
        let side = workingSide
        let probes = [0.35, 0.42, 0.5, 0.58, 0.65].map { Int(Double(side) * $0) }

        // Global light/dark split from a sparse sample.
        var minV = 255, maxV = 0
        for y in stride(from: 0, to: side, by: 37) {
            for x in stride(from: 0, to: side, by: 37) {
                let v = luminance(x: x, y: y)
                minV = min(minV, v)
                maxV = max(maxV, v)
            }
        }
        guard maxV - minV > 40 else { return nil }
        let threshold = (minV + maxV) / 2

        func edge(values: (Int) -> Int, limit: Int) -> Int? {
            // Walk inward. A short initial dark run means the detected quad
            // was the symbol's frame itself — its outer edge is right here. A
            // long one is dark background around the card; skip it and find
            // the light→dark transition of the real frame further in.
            var index = 0
            let maxInitialDark = side * 8 / 100
            while index < limit, values(index) < threshold { index += 1 }
            if index > 0, index <= maxInitialDark { return 0 }
            var litRun = 0
            while index < limit {
                if values(index) >= threshold {
                    litRun += 1
                } else if litRun >= 3 {
                    // Confirm a sustained dark run (the 2-module frame).
                    var darkRun = 0
                    var j = index
                    while j < limit, values(j) < threshold, darkRun < 4 {
                        darkRun += 1
                        j += 1
                    }
                    if darkRun >= 3 { return index }
                    litRun = 0
                } else {
                    litRun = 0
                }
                index += 1
            }
            return nil
        }

        func median(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }

        let limit = side / 2
        let lefts = probes.compactMap { y in edge(values: { self.luminance(x: $0, y: y) }, limit: limit) }
        let rights = probes.compactMap { y in
            edge(values: { self.luminance(x: side - 1 - $0, y: y) }, limit: limit).map { side - 1 - $0 }
        }
        let tops = probes.compactMap { x in edge(values: { self.luminance(x: x, y: $0) }, limit: limit) }
        let bottoms = probes.compactMap { x in
            edge(values: { self.luminance(x: x, y: side - 1 - $0) }, limit: limit).map { side - 1 - $0 }
        }

        guard lefts.count >= 3, rights.count >= 3, tops.count >= 3, bottoms.count >= 3,
              let left = median(lefts), let right = median(rights),
              let top = median(tops), let bottom = median(bottoms)
        else { return nil }

        let width = right - left
        let height = bottom - top
        guard width > side / 3, height > side / 3 else { return nil }
        // The symbol is square; badly skewed bounds mean a bad detection.
        guard abs(width - height) < max(width, height) / 8 else { return nil }
        return (left, right, top, bottom)
    }

    /// Locates the orb's bright ring on its dark card by probing inward near
    /// the midlines of each edge. Near a midline the circle's extreme points
    /// coincide with its bounding box, so the same box-probing scheme as the
    /// square frame works — with the polarity flipped.
    private func locateRing() -> (left: Int, right: Int, top: Int, bottom: Int)? {
        let side = workingSide
        // Tight around the midlines: a circle's edge shifts only ~0.2% of the
        // radius within 5% of the midline, well under one module.
        let probes = [0.46, 0.5, 0.54].map { Int(Double(side) * $0) }

        var minV = 255, maxV = 0
        for y in stride(from: 0, to: side, by: 37) {
            for x in stride(from: 0, to: side, by: 37) {
                let v = luminance(x: x, y: y)
                minV = min(minV, v)
                maxV = max(maxV, v)
            }
        }
        guard maxV - minV > 40 else { return nil }
        let threshold = (minV + maxV) / 2

        func edge(values: (Int) -> Int, limit: Int) -> Int? {
            // Walk inward: skip the card's thin bright border if the quad
            // included it, require dark (the card margin), then the first
            // sustained bright run is the ring's outer edge.
            var index = 0
            let maxBorder = side * 3 / 100
            while index < maxBorder, values(index) >= threshold { index += 1 }
            var darkRun = 0
            while index < limit {
                if values(index) < threshold {
                    darkRun += 1
                } else if darkRun >= 3 {
                    var brightRun = 0
                    var j = index
                    while j < limit, values(j) >= threshold, brightRun < 4 {
                        brightRun += 1
                        j += 1
                    }
                    if brightRun >= 3 { return index }
                    darkRun = 0
                } else {
                    darkRun = 0
                }
                index += 1
            }
            return nil
        }

        func median(_ values: [Int]) -> Int? {
            guard !values.isEmpty else { return nil }
            return values.sorted()[values.count / 2]
        }

        let limit = side / 2
        let lefts = probes.compactMap { y in edge(values: { self.luminance(x: $0, y: y) }, limit: limit) }
        let rights = probes.compactMap { y in
            edge(values: { self.luminance(x: side - 1 - $0, y: y) }, limit: limit).map { side - 1 - $0 }
        }
        let tops = probes.compactMap { x in edge(values: { self.luminance(x: x, y: $0) }, limit: limit) }
        let bottoms = probes.compactMap { x in
            edge(values: { self.luminance(x: x, y: side - 1 - $0) }, limit: limit).map { side - 1 - $0 }
        }

        guard lefts.count >= 2, rights.count >= 2, tops.count >= 2, bottoms.count >= 2,
              let left = median(lefts), let right = median(rights),
              let top = median(tops), let bottom = median(bottoms)
        else { return nil }

        let width = right - left
        let height = bottom - top
        guard width > side / 3, height > side / 3 else { return nil }
        guard abs(width - height) < max(width, height) / 8 else { return nil }
        return (left, right, top, bottom)
    }

    private func attemptDecodeOrb(ringBounds: (left: Int, right: Int, top: Int, bottom: Int)) -> Data? {
        let candidates = (lockedShape == .orb ? lockedSize : nil).map { [$0] } ?? DenseMatrixCode.sizes
        let width = Float(ringBounds.right - ringBounds.left)
        let height = Float(ringBounds.bottom - ringBounds.top)

        for n in candidates {
            let pitchX = width / Float(n)
            let pitchY = height / Float(n)
            guard pitchX >= 2.2 else { continue }

            // The orb samples the full bounding grid; the codec masks out
            // everything that is not a data cell.
            var samples = [Float](repeating: 0, count: n * n)
            for row in 0 ..< n {
                let cy = Float(ringBounds.top) + (Float(row) + 0.5) * pitchY
                for col in 0 ..< n {
                    let cx = Float(ringBounds.left) + (Float(col) + 0.5) * pitchX
                    samples[row * n + col] = sampleCell(cx: cx, cy: cy)
                }
            }

            let averaged: [Float]
            if var acc = orbAccumulators[n] {
                for i in 0 ..< acc.count {
                    acc[i] = acc[i] * 0.75 + samples[i] * 0.25
                }
                orbAccumulators[n] = acc
                averaged = acc
            } else {
                orbAccumulators[n] = samples
                averaged = samples
            }

            for grid in [averaged, samples] {
                if let payload = DenseMatrixCode.decodeOrb(gridLuminances: grid, size: n)
                    ?? DenseMatrixCode.decodeOrb(gridLuminances: Self.mirrored(grid, side: n), size: n)
                {
                    return payload
                }
            }

            if lockedSize == nil, DenseMatrixCode.orbHeaderReads(gridLuminances: averaged, size: n) {
                lockedSize = n
                lockedShape = .orb
            }
        }
        return nil
    }

    private func attemptDecode(frameBounds: (left: Int, right: Int, top: Int, bottom: Int)) -> Data? {
        let candidates = (lockedShape == .square ? lockedSize : nil).map { [$0] } ?? DenseMatrixCode.sizes
        let width = Float(frameBounds.right - frameBounds.left)
        let height = Float(frameBounds.bottom - frameBounds.top)

        for n in candidates {
            let pitchX = width / Float(n)
            let pitchY = height / Float(n)
            guard pitchX >= 2.2 else { continue }

            let inner = n - 2 * DenseMatrixCode.borderModules
            var samples = [Float](repeating: 0, count: inner * inner)
            for row in 0 ..< inner {
                let cy = Float(frameBounds.top) + (Float(DenseMatrixCode.borderModules + row) + 0.5) * pitchY
                for col in 0 ..< inner {
                    let cx = Float(frameBounds.left) + (Float(DenseMatrixCode.borderModules + col) + 0.5) * pitchX
                    samples[row * inner + col] = sampleCell(cx: cx, cy: cy)
                }
            }

            // Fold into the running average for this size hypothesis. An EMA
            // rather than a plain mean, so a bad early frame cannot poison
            // the vote forever.
            let averaged: [Float]
            if var acc = accumulators[n] {
                for i in 0 ..< acc.count {
                    acc[i] = acc[i] * 0.75 + samples[i] * 0.25
                }
                accumulators[n] = acc
                averaged = acc
            } else {
                accumulators[n] = samples
                averaged = samples
            }

            for grid in [averaged, samples] {
                // The render path's vertical convention is an implementation
                // detail; trying the mirrored grid too covers all eight
                // orientations together with the codec's rotation trials.
                if let payload = DenseMatrixCode.decode(interiorLuminances: grid, size: n)
                    ?? DenseMatrixCode.decode(interiorLuminances: Self.mirrored(grid, side: inner), size: n)
                {
                    return payload
                }
            }

            // Lock the size once its header reads, so later frames stop
            // wasting time on the other hypotheses.
            if lockedSize == nil, headerReads(averaged, inner: inner, size: n) {
                lockedSize = n
                lockedShape = .square
            }
        }
        return nil
    }

    private func headerReads(_ luminances: [Float], inner: Int, size n: Int) -> Bool {
        guard let threshold = DenseMatrixCode.otsuThreshold(luminances) else { return false }
        var bits = luminances.map { $0 < threshold }
        for _ in 0 ..< 4 {
            if let header = DenseMatrixCode.decodeHeader(bits: bits), header.size == n {
                return true
            }
            bits = DenseMatrixCode.rotateClockwise(bits, side: inner)
        }
        return false
    }

    /// Mean of a 3×3 pixel neighborhood at the cell center.
    private func sampleCell(cx: Float, cy: Float) -> Float {
        let x = Int(cx.rounded())
        let y = Int(cy.rounded())
        var sum = 0
        var count = 0
        for dy in -1 ... 1 {
            let yy = y + dy
            guard yy >= 0, yy < workingSide else { continue }
            for dx in -1 ... 1 {
                let xx = x + dx
                guard xx >= 0, xx < workingSide else { continue }
                sum += luminance(x: xx, y: yy)
                count += 1
            }
        }
        return count > 0 ? Float(sum) / Float(count) : 0
    }

    static func mirrored(_ grid: [Float], side: Int) -> [Float] {
        var out = grid
        for row in 0 ..< side {
            for col in 0 ..< side {
                out[row * side + col] = grid[row * side + (side - 1 - col)]
            }
        }
        return out
    }
}
