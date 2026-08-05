import Foundation
import Swinject

/// Per-cycle who/what/where/when/why/how audit record
/// (docs/ML_DOSING_REPLACEMENT_PLAN.md §2.5).
///
/// One record is written for every dosing decision — including no-action and
/// fallback cycles — so any dose can be reconstructed after the fact from the
/// stored record alone. Records are appended as JSON Lines to daily files under
/// Documents/decision_audit/, which makes them trivially exportable and
/// tail-able without a database migration.
struct DecisionAuditRecord: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DecisionAuditRecord.currentSchemaVersion

    /// Which system, in which configuration, made this decision.
    struct Who: Codable {
        let algorithm: String // "oref" | "ml" | "fallback-zero-temp"
        let appVersion: String?
        let modelVersion: String? // nil while oref decides
        let closedLoop: Bool
        let maxIOB: Decimal
        let maxBolus: Decimal
        let maxBasal: Decimal
        let maxSMBBasalMinutes: Decimal
        let smbIntervalMinutes: Decimal
        let thresholdSetting: Decimal
    }

    /// The action itself, proposed and (if different) as clamped.
    struct What: Codable {
        let rate: Decimal?
        let durationMinutes: Decimal?
        let smbUnits: Decimal?
        let carbsRequired: Decimal?
        let outcome: String // "dose" | "no-action" | "suspend" | "hold"
        let clamps: [String] // human-readable description of each envelope clamp that fired
    }

    /// The path the decision took through the pipeline.
    struct Path: Codable {
        let pipeline: String // "oref" | "ml" | "ml→oref-fallback"
        let terminatedBy: String? // e.g. "envelope: LGS override", nil when unclamped
    }

    struct When: Codable {
        let trigger: String // "cgm" | "manual" | "carbs" | "bolus"
        let decisionAt: Date
        let deliverAt: Date?
        let glucoseValue: Decimal?
    }

    /// The rationale: predictions, binding constraints, and the algorithm's own reason.
    struct Why: Codable {
        let reason: String
        let eventualBG: Decimal?
        let minPredBG: Decimal?
        let iob: Decimal?
        let cob: Decimal?
        let isf: Decimal?
        let sensitivityRatio: Decimal?
        let threshold: Decimal?
        let insulinReq: Decimal?
    }

    /// Mechanics: what was searched/produced, for reproducibility.
    struct How: Codable {
        let predictionPointCounts: [String: Int] // "IOB"/"ZT"/"COB"/"UAM" → number of 5-min steps
        let tdd: Decimal?
        let carbRatio: Decimal?
    }

    let who: Who
    let what: What
    let path: Path
    let when: When
    let why: Why
    let how: How

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case who
        case what
        case path = "where"
        case when
        case why
        case how
    }
}

/// Append-only JSONL persistence for audit records: one file per day,
/// `decision_audit/audit-YYYY-MM-DD.jsonl`, retained for 90 days.
final class DecisionAuditFileStore {
    private let directory: URL
    private let queue = DispatchQueue(label: "DecisionAuditFileStore.queue", qos: .utility)
    private let encoder: JSONEncoder
    private let retentionDays = 90

    init(baseDirectory: URL? = nil) {
        let documents = baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("decision_audit", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        queue.async { [weak self] in
            self?.createDirectoryIfNeeded()
            self?.purgeExpiredFiles()
        }
    }

    func append(_ record: DecisionAuditRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try encoder.encode(record)
                let url = fileURL(for: record.when.decisionAt)
                if FileManager.default.fileExists(atPath: url.path) {
                    let handle = try FileHandle(forWritingTo: url)
                    defer { try? handle.close() }
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data + Data("\n".utf8))
                } else {
                    createDirectoryIfNeeded()
                    try (data + Data("\n".utf8)).write(to: url, options: .atomic)
                }
            } catch {
                debug(.apsManager, "DecisionAudit: failed to append record: \(error)")
            }
        }
    }

    /// All existing audit files, oldest first — for the export/share UI.
    func auditFileURLs() -> [URL] {
        queue.sync {
            let urls = (try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil
            )) ?? []
            return urls.filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    private func fileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return directory.appendingPathComponent("audit-\(formatter.string(from: date)).jsonl")
    }

    private func createDirectoryIfNeeded() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func purgeExpiredFiles() {
        let cutoff = Date().addingTimeInterval(-Double(retentionDays) * 24 * 60 * 60)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        for url in urls {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}

protocol DecisionAuditService {
    /// All audit files on disk, oldest first, for export.
    func auditFileURLs() -> [URL]
}

/// Observes every published determination and writes its audit record.
///
/// Wired into the existing oref path via `DeterminationObserver` — the plan calls
/// for audit visibility to start before any ML component ever doses. When the ML
/// engine lands, it reports through the same store with `algorithm: "ml"` and its
/// envelope clamp list.
final class BaseDecisionAuditService: DecisionAuditService, Injectable {
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var settingsManager: SettingsManager!

    private let store: DecisionAuditFileStore

    init(resolver: Resolver) {
        store = DecisionAuditFileStore()
        injectServices(resolver)
        broadcaster.register(DeterminationObserver.self, observer: self)
    }

    func auditFileURLs() -> [URL] {
        store.auditFileURLs()
    }
}

extension BaseDecisionAuditService: DeterminationObserver {
    func determinationDidUpdate(_ determination: Determination) {
        let preferences = settingsManager.preferences
        let pumpSettings = settingsManager.pumpSettings

        let outcome: String
        if (determination.units ?? 0) > 0 || (determination.rate ?? 0) > 0 {
            outcome = "dose"
        } else if determination.rate == 0, (determination.duration ?? 0) > 0 {
            outcome = "suspend"
        } else {
            outcome = "no-action"
        }

        let record = DecisionAuditRecord(
            who: .init(
                algorithm: "oref",
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                modelVersion: nil,
                closedLoop: settingsManager.settings.closedLoop,
                maxIOB: preferences.maxIOB,
                maxBolus: pumpSettings.maxBolus,
                maxBasal: pumpSettings.maxBasal,
                maxSMBBasalMinutes: preferences.maxSMBBasalMinutes,
                smbIntervalMinutes: preferences.smbInterval,
                thresholdSetting: preferences.threshold_setting
            ),
            what: .init(
                rate: determination.rate,
                durationMinutes: determination.duration,
                smbUnits: determination.units,
                carbsRequired: determination.carbsReq,
                outcome: outcome,
                clamps: []
            ),
            path: .init(pipeline: "oref", terminatedBy: nil),
            when: .init(
                trigger: "cgm",
                decisionAt: determination.timestamp ?? Date(),
                deliverAt: determination.deliverAt,
                glucoseValue: determination.bg
            ),
            why: .init(
                reason: determination.reason,
                eventualBG: determination.eventualBG.map { Decimal($0) },
                minPredBG: determination.minPredBG,
                iob: determination.iob,
                cob: determination.cob,
                isf: determination.isf,
                sensitivityRatio: determination.sensitivityRatio,
                threshold: determination.threshold,
                insulinReq: determination.insulinReq
            ),
            how: .init(
                predictionPointCounts: [
                    "IOB": determination.predictions?.iob?.count ?? 0,
                    "ZT": determination.predictions?.zt?.count ?? 0,
                    "COB": determination.predictions?.cob?.count ?? 0,
                    "UAM": determination.predictions?.uam?.count ?? 0
                ],
                tdd: determination.tdd,
                carbRatio: determination.carbRatio
            )
        )
        store.append(record)
    }
}
