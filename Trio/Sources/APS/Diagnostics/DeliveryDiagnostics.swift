import Foundation
import Swinject

/// One insulin delivery command Trio handed to the pump, with the timing and
/// outcome nothing else records.
///
/// Trio already stores what the algorithm *decided* (`OrefDetermination`,
/// `DecisionAuditRecord`) and what the pump *reported afterwards*
/// (`PumpEventStored`). Neither answers the question this record exists for:
/// when did Trio ask, how long did the pump take to answer, and did the ask
/// survive the trip. A dose oref sized correctly still arrives late — or never —
/// if the command sat in a BLE retry for forty seconds, was clamped by a
/// delivery cap on the way out, or was never sent because the pump was
/// suspended. Those failure modes are invisible in every other store, and they
/// are the ones that make a correctly tuned loop feel underpowered.
struct DeliveryCommandRecord: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int = DeliveryCommandRecord.currentSchemaVersion

    enum Kind: String, Codable {
        case tempBasal
        case smb
        case manualBolus
        case cancelBolus
        case suspend
        case resume
    }

    enum Outcome: String, Codable {
        /// The pump manager returned without throwing.
        case succeeded
        /// The pump manager threw; `error` carries the description.
        case failed
        /// Trio never sent the command; `error` carries the reason. This is the
        /// case that hides missing insulin — no pump event is ever written, so
        /// only this record shows the dose was dropped.
        case notSent
    }

    let kind: Kind
    /// Temp basal rate in U/hr; nil for boluses.
    let requestedRate: Decimal?
    /// Temp basal duration in minutes; nil for boluses.
    let requestedDurationMinutes: Decimal?
    /// Bolus or SMB size in units; nil for temp basals.
    let requestedUnits: Decimal?
    /// When Trio handed the command to the pump manager.
    let issuedAt: Date
    /// When the pump manager returned, successfully or not. Equal to `issuedAt`
    /// when nothing was sent.
    let completedAt: Date
    /// Round trip in seconds — the "quickly enough" number.
    let latencySeconds: Double
    let outcome: Outcome
    let error: String?
    /// `deliverAt` of the determination this command came from, so a command
    /// joins to its cycle. Nil for manual boluses and user-driven actions.
    let determinationDeliverAt: Date?
    /// Anything that reduced the dose between determination and command —
    /// delivery caps today, further safety clamps later. Empty when the command
    /// carried the determination through unchanged.
    let clamps: [String]

    init(
        kind: Kind,
        requestedRate: Decimal? = nil,
        requestedDurationMinutes: Decimal? = nil,
        requestedUnits: Decimal? = nil,
        issuedAt: Date,
        completedAt: Date,
        outcome: Outcome,
        error: String? = nil,
        determinationDeliverAt: Date? = nil,
        clamps: [String] = []
    ) {
        self.kind = kind
        self.requestedRate = requestedRate
        self.requestedDurationMinutes = requestedDurationMinutes
        self.requestedUnits = requestedUnits
        self.issuedAt = issuedAt
        self.completedAt = completedAt
        latencySeconds = completedAt.timeIntervalSince(issuedAt)
        self.outcome = outcome
        self.error = error
        self.determinationDeliverAt = determinationDeliverAt
        self.clamps = clamps
    }
}

/// Append-only JSONL persistence for delivery commands: one file per UTC day,
/// `delivery_diagnostics/delivery-YYYY-MM-DD.jsonl`.
///
/// Retention is 14 days — twice the longest window the export offers, so a
/// 7-day export is never truncated by a purge that ran mid-window.
final class DeliveryCommandFileStore {
    private let directory: URL
    private let queue = DispatchQueue(label: "DeliveryCommandFileStore.queue", qos: .utility)
    private let encoder: JSONEncoder
    private let retentionDays = 14

    init(baseDirectory: URL? = nil) {
        let documents = baseDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("delivery_diagnostics", isDirectory: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        queue.async { [weak self] in
            self?.createDirectoryIfNeeded()
            self?.purgeExpiredFiles()
        }
    }

    /// Appends off the caller's thread — this sits directly in the dosing path
    /// and must never add latency to the very thing it measures.
    func append(_ record: DeliveryCommandRecord) {
        queue.async { [weak self] in
            guard let self else { return }
            do {
                let data = try encoder.encode(record)
                let url = fileURL(for: record.issuedAt)
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
                debug(.apsManager, "DeliveryDiagnostics: failed to append command record: \(error)")
            }
        }
    }

    /// Every command issued within `[start, end]`, oldest first. A malformed
    /// line is skipped rather than losing the rest of the day.
    func records(from start: Date, to end: Date) -> [DeliveryCommandRecord] {
        queue.sync {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return urls
                .filter { $0.pathExtension == "jsonl" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
                .flatMap { url -> [DeliveryCommandRecord] in
                    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
                    return text.split(separator: "\n")
                        .compactMap { try? decoder.decode(DeliveryCommandRecord.self, from: Data($0.utf8)) }
                }
                .filter { $0.issuedAt >= start && $0.issuedAt <= end }
                .sorted { $0.issuedAt < $1.issuedAt }
        }
    }

    private func fileURL(for date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return directory.appendingPathComponent("delivery-\(formatter.string(from: date)).jsonl")
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

protocol DeliveryDiagnosticsRecorder {
    func record(_ record: DeliveryCommandRecord)
    /// Every command issued within `[start, end]`, oldest first.
    func records(from start: Date, to end: Date) -> [DeliveryCommandRecord]
}

final class BaseDeliveryDiagnosticsRecorder: DeliveryDiagnosticsRecorder {
    private let store: DeliveryCommandFileStore

    init(store: DeliveryCommandFileStore = DeliveryCommandFileStore()) {
        self.store = store
    }

    func record(_ record: DeliveryCommandRecord) {
        store.append(record)
    }

    func records(from start: Date, to end: Date) -> [DeliveryCommandRecord] {
        store.records(from: start, to: end)
    }
}

/// Times a delivery command and records it whatever way it ends.
///
/// Wrapping rather than hand-writing the timestamps at each call site is what
/// keeps the failure paths honest: a `throw` out of the middle of `body` still
/// produces a record, so a pump that rejects every SMB leaves the same trail as
/// one that accepts them.
extension DeliveryDiagnosticsRecorder {
    func timing<T>(
        kind: DeliveryCommandRecord.Kind,
        requestedRate: Decimal? = nil,
        requestedDurationMinutes: Decimal? = nil,
        requestedUnits: Decimal? = nil,
        determinationDeliverAt: Date? = nil,
        clamps: [String] = [],
        body: () async throws -> T
    ) async throws -> T {
        let issuedAt = Date()
        do {
            let result = try await body()
            record(DeliveryCommandRecord(
                kind: kind,
                requestedRate: requestedRate,
                requestedDurationMinutes: requestedDurationMinutes,
                requestedUnits: requestedUnits,
                issuedAt: issuedAt,
                completedAt: Date(),
                outcome: .succeeded,
                determinationDeliverAt: determinationDeliverAt,
                clamps: clamps
            ))
            return result
        } catch {
            record(DeliveryCommandRecord(
                kind: kind,
                requestedRate: requestedRate,
                requestedDurationMinutes: requestedDurationMinutes,
                requestedUnits: requestedUnits,
                issuedAt: issuedAt,
                completedAt: Date(),
                outcome: .failed,
                error: String(describing: error),
                determinationDeliverAt: determinationDeliverAt,
                clamps: clamps
            ))
            throw error
        }
    }

    /// Records a command Trio chose not to send at all.
    func recordNotSent(
        kind: DeliveryCommandRecord.Kind,
        requestedRate: Decimal? = nil,
        requestedDurationMinutes: Decimal? = nil,
        requestedUnits: Decimal? = nil,
        reason: String,
        determinationDeliverAt: Date? = nil,
        clamps: [String] = []
    ) {
        let now = Date()
        record(DeliveryCommandRecord(
            kind: kind,
            requestedRate: requestedRate,
            requestedDurationMinutes: requestedDurationMinutes,
            requestedUnits: requestedUnits,
            issuedAt: now,
            completedAt: now,
            outcome: .notSent,
            error: reason,
            determinationDeliverAt: determinationDeliverAt,
            clamps: clamps
        ))
    }
}
