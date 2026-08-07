import SwiftUI

/// Human-in-the-loop review UI for on-device shadow-forecaster candidates.
///
/// Shows the active model, the latest retrain report, and — when a candidate
/// passed its gates — the full gate report with Promote/Reject actions.
/// Promotion only changes which model records *shadow* forecasts; nothing
/// reviewed here can influence dosing.
struct MLModelReviewSection: View {
    @State private var candidate: MLModelStore.Document?
    @State private var lastReport: MLEvalReport?
    @State private var activeVersion: String = "factory"
    @State private var isRetraining = false
    @State private var showPromoteConfirmation = false
    @State private var actionError: String?

    var body: some View {
        Section(
            header: Text("Shadow Forecaster Model"),
            content: {
                HStack {
                    Text("Active model")
                    Spacer()
                    Text("v\(activeVersion)").foregroundStyle(.secondary)
                }

                if let candidate = candidate, let report = candidate.evalReport {
                    candidateCard(candidate, report)
                } else if let report = lastReport, !report.passed {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Last retrain: champion retained")
                        ForEach(report.gates.filter { !$0.passed }, id: \.name) { gate in
                            Label("\(gate.name): \(gate.detail)", systemImage: "xmark.circle")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else if lastReport == nil {
                    Text("No retrain has run yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    isRetraining = true
                    MLRetrainService.shared.retrainNow { _ in
                        Task { @MainActor in
                            isRetraining = false
                            reload()
                        }
                    }
                } label: {
                    HStack {
                        Text("Retrain Now")
                        Spacer()
                        if isRetraining { ProgressView() }
                    }
                }
                .disabled(isRetraining)

                if let actionError = actionError {
                    Text(actionError).font(.footnote).foregroundStyle(.red)
                }

                Text("Candidates are trained on this device from your own data and only ever produce the shadow forecasts shown in Statistics. Promotion never affects insulin dosing.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        )
        .listRowBackground(Color.chart)
        .onAppear(perform: reload)
        .confirmationDialog(
            "Promote candidate v\(candidate?.versionNumber ?? 0)?",
            isPresented: $showPromoteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Promote — use for shadow forecasts") {
                perform { try MLModelStore.shared.promote(version: candidate?.versionNumber ?? 0) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The candidate becomes the active shadow forecaster. The current model is retired but kept for rollback.")
        }
    }

    @ViewBuilder private func candidateCard(_ candidate: MLModelStore.Document, _ report: MLEvalReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(
                "Candidate v\(candidate.versionNumber) awaiting review",
                systemImage: "checkmark.seal"
            )
            .font(.subheadline.weight(.semibold))

            Text("Trained on \(report.trainedOnSamples) samples · \(report.walkForwardDays) walk-forward days")
                .font(.footnote)
                .foregroundStyle(.secondary)

            ForEach(report.horizons.sorted(by: { $0.key < $1.key }), id: \.key) { horizon, eval in
                HStack {
                    Text("\(horizon) min")
                    Spacer()
                    Text(String(
                        format: "cand %.1f · persist %.1f%@",
                        eval.candidateMAE,
                        eval.persistenceMAE,
                        eval.championMAE.map { String(format: " · champ %.1f", $0) } ?? ""
                    ))
                    .foregroundStyle(.secondary)
                }
                .font(.footnote.monospacedDigit())
            }

            ForEach(report.gates, id: \.name) { gate in
                Label("\(gate.name): \(gate.detail)", systemImage: gate.passed ? "checkmark.circle" : "xmark.circle")
                    .font(.caption2)
                    .foregroundStyle(gate.passed ? Color.secondary : Color.red)
            }

            if report.invalidReadingsDropped > 0 || report.skippedGap > 0 {
                Text("Data quality: \(report.invalidReadingsDropped) invalid readings dropped, \(report.skippedGap) gap-skipped samples — review the CGM Gaps chart before promoting.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            HStack {
                Button("Promote") { showPromoteConfirmation = true }
                    .buttonStyle(.borderedProminent)
                Button("Reject", role: .destructive) {
                    perform { try MLModelStore.shared.reject(version: candidate.versionNumber) }
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 2)
        }
    }

    private func perform(_ action: () throws -> Void) {
        do {
            try action()
            actionError = nil
        } catch {
            actionError = error.localizedDescription
        }
        reload()
    }

    private func reload() {
        candidate = MLModelStore.shared.pendingCandidate()
        lastReport = MLModelStore.shared.lastRetrainReport()
        if let promoted = MLModelStore.shared.allDocuments().last(where: { $0.status == .promoted }) {
            activeVersion = String(promoted.versionNumber)
        } else if let bundled = MLForecastService.bundledModel() {
            activeVersion = "\(bundled.modelVersion) (bundled)"
        } else {
            activeVersion = "none"
        }
    }
}
