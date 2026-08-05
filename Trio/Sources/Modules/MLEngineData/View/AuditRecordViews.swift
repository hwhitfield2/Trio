import SwiftUI

/// In-app browser for decision-audit records: one day's cycles as a list, each
/// opening the full who/what/where/when/why/how detail.

struct AuditDayView: View {
    let fileURL: URL
    let loader: (URL) -> [DecisionAuditRecord]

    @State private var records: [DecisionAuditRecord] = []
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        List {
            if records.isEmpty {
                Section {
                    Text("No records in this file.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }.listRowBackground(Color.chart)
            } else {
                Section(
                    footer: Text("\(records.count) decisions, newest first. Tap a decision for the full record."),
                    content: {
                        ForEach(Array(records.enumerated()), id: \.offset) { _, record in
                            NavigationLink {
                                AuditRecordDetailView(record: record)
                            } label: {
                                row(for: record)
                            }
                        }
                    }
                ).listRowBackground(Color.chart)
            }
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .onAppear { records = loader(fileURL) }
        .navigationBarTitle(fileURL.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "audit-", with: ""))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: fileURL) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }

    private func row(for record: DecisionAuditRecord) -> some View {
        HStack(spacing: 10) {
            Text(Self.timeFormatter.string(from: record.when.decisionAt))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    outcomeBadge(record.what.outcome)
                    if let glucose = record.when.glucoseValue {
                        Text("\(glucose) mg/dL").font(.subheadline)
                    }
                }
                Text(deliverySummary(record))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !record.what.clamps.isEmpty {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(.orange)
                    .font(.footnote)
            }
        }
    }

    private func deliverySummary(_ record: DecisionAuditRecord) -> String {
        var parts: [String] = []
        if let rate = record.what.rate, let duration = record.what.durationMinutes {
            parts.append("\(rate) U/hr × \(duration) min")
        }
        if let smb = record.what.smbUnits, smb > 0 {
            parts.append("SMB \(smb) U")
        }
        if let iob = record.why.iob {
            parts.append("IOB \(iob)")
        }
        return parts.isEmpty ? record.who.algorithm : parts.joined(separator: " · ")
    }

    private func outcomeBadge(_ outcome: String) -> some View {
        Text(outcome)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(badgeColor(outcome).opacity(0.2))
            .foregroundStyle(badgeColor(outcome))
            .clipShape(Capsule())
    }

    private func badgeColor(_ outcome: String) -> Color {
        switch outcome {
        case "dose": return .blue
        case "suspend": return .orange
        case "hold": return .yellow
        default: return .secondary
        }
    }
}

struct AuditRecordDetailView: View {
    let record: DecisionAuditRecord

    @Environment(\.colorScheme) var colorScheme
    @Environment(AppState.self) var appState

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        List {
            Section(header: Text("What")) {
                labeled("Outcome", record.what.outcome)
                if let rate = record.what.rate { labeled("Temp basal", "\(rate) U/hr") }
                if let duration = record.what.durationMinutes { labeled("Duration", "\(duration) min") }
                if let smb = record.what.smbUnits { labeled("SMB", "\(smb) U") }
                if let carbsRequired = record.what.carbsRequired, carbsRequired > 0 {
                    labeled("Carbs required", "\(carbsRequired) g")
                }
                if !record.what.clamps.isEmpty {
                    ForEach(record.what.clamps, id: \.self) { clamp in
                        Label(clamp, systemImage: "exclamationmark.shield")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }.listRowBackground(Color.chart)

            Section(header: Text("Why")) {
                if let eventualBG = record.why.eventualBG { labeled("Eventual BG", "\(eventualBG) mg/dL") }
                if let minPredBG = record.why.minPredBG { labeled("Min predicted BG", "\(minPredBG) mg/dL") }
                if let threshold = record.why.threshold { labeled("Threshold", "\(threshold) mg/dL") }
                if let iob = record.why.iob { labeled("IOB", "\(iob) U") }
                if let cob = record.why.cob { labeled("COB", "\(cob) g") }
                if let insulinReq = record.why.insulinReq { labeled("Insulin required", "\(insulinReq) U") }
                if let isf = record.why.isf { labeled("ISF", "\(isf)") }
                if let ratio = record.why.sensitivityRatio { labeled("Sensitivity ratio", "\(ratio)") }
                Text(record.why.reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }.listRowBackground(Color.chart)

            Section(header: Text("When")) {
                labeled("Trigger", record.when.trigger)
                labeled("Decision", Self.timestampFormatter.string(from: record.when.decisionAt))
                if let deliverAt = record.when.deliverAt {
                    labeled("Deliver at", Self.timestampFormatter.string(from: deliverAt))
                }
                if let glucose = record.when.glucoseValue { labeled("Glucose", "\(glucose) mg/dL") }
            }.listRowBackground(Color.chart)

            Section(header: Text("Who")) {
                labeled("Algorithm", record.who.algorithm)
                if let version = record.who.appVersion { labeled("App version", version) }
                if let model = record.who.modelVersion { labeled("Model version", model) }
                labeled("Closed loop", record.who.closedLoop ? "on" : "off")
                labeled("Max IOB", "\(record.who.maxIOB) U")
                labeled("Max bolus", "\(record.who.maxBolus) U")
                labeled("Max basal", "\(record.who.maxBasal) U/hr")
                labeled("Max SMB basal minutes", "\(record.who.maxSMBBasalMinutes)")
                labeled("SMB interval", "\(record.who.smbIntervalMinutes) min")
                labeled("Threshold setting", "\(record.who.thresholdSetting) mg/dL")
            }.listRowBackground(Color.chart)

            Section(header: Text("Where")) {
                labeled("Pipeline", record.path.pipeline)
                if let terminatedBy = record.path.terminatedBy { labeled("Terminated by", terminatedBy) }
            }.listRowBackground(Color.chart)

            Section(header: Text("How")) {
                ForEach(record.how.predictionPointCounts.sorted(by: { $0.key < $1.key }), id: \.key) { key, count in
                    labeled("\(key) forecast points", "\(count)")
                }
                if let tdd = record.how.tdd { labeled("TDD", "\(tdd) U") }
                if let carbRatio = record.how.carbRatio { labeled("Carb ratio", "\(carbRatio) g/U") }
            }.listRowBackground(Color.chart)
        }
        .scrollContentBackground(.hidden).background(appState.trioBackgroundColor(for: colorScheme))
        .navigationBarTitle(Self.timestampFormatter.string(from: record.when.decisionAt))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func labeled(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
