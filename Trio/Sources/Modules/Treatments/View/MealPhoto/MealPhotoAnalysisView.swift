import SwiftUI

/// Full meal-photo flow presented from the bolus calculator:
/// capture (with scale-reference overlay) -> AI analysis -> review -> apply to the meal entry.
struct MealPhotoAnalysisView: View {
    @Bindable var state: Treatments.StateModel
    /// Called after an accepted result has been applied to the state model, so
    /// non-router presenters (the Home carbs drawer) can sync their local UI.
    var onApplied: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private enum Phase {
        case capture
        case analyzing(UIImage)
        case result(UIImage, MealPhotoAnalysisResult)
        case failed(UIImage, String)
    }

    @State private var phase: Phase = .capture
    @State private var selectedReference: ScaleReferenceObject = .sodaCan
    @State private var analysisTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            content
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if !isCapturePhase {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                analysisTask?.cancel()
                                dismiss()
                            }
                        }
                    }
                }
        }
        .interactiveDismissDisabled(isAnalyzing)
    }

    private var isCapturePhase: Bool {
        if case .capture = phase { return true }
        return false
    }

    private var isAnalyzing: Bool {
        if case .analyzing = phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .capture:
            MealPhotoCaptureView(
                selectedReference: $selectedReference,
                onCapture: { image in
                    startAnalysis(of: image)
                },
                onCancel: { dismiss() }
            )
            .toolbar(.hidden, for: .navigationBar)

        case let .analyzing(image):
            analyzingView(image)
                .navigationTitle("Analyzing Meal")

        case let .result(image, result):
            MealPhotoResultView(
                image: image,
                result: result,
                showsFatProtein: true,
                onAccept: {
                    state.applyMealPhotoAnalysis(result)
                    onApplied?()
                    dismiss()
                },
                onRetake: { phase = .capture }
            )
            .navigationTitle("Meal Analysis")

        case let .failed(image, message):
            failedView(image, message: message)
                .navigationTitle("Analysis Failed")
        }
    }

    private func analyzingView(_ image: UIImage) -> some View {
        ZStack {
            appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 20) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .blur(radius: 2)

                ProgressView()
                    .controlSize(.large)

                Text("Identifying components and estimating carbs...")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    private func failedView(_ image: UIImage, message: String) -> some View {
        ZStack {
            appState.trioBackgroundColor(for: colorScheme).ignoresSafeArea()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)

                Text(message)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    startAnalysis(of: image)
                } label: {
                    Text("Try Again").frame(maxWidth: 200)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    phase = .capture
                } label: {
                    Text("Retake Photo").frame(maxWidth: 200)
                }
                .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private func startAnalysis(of image: UIImage) {
        phase = .analyzing(image)
        analysisTask = Task {
            do {
                let result = try await state.analyzeMealPhoto(image, scaleReference: selectedReference)
                guard !Task.isCancelled else { return }
                await MainActor.run { phase = .result(image, result) }
            } catch {
                guard !Task.isCancelled else { return }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { phase = .failed(image, message) }
            }
        }
    }
}
