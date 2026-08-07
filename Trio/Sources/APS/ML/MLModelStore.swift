import Foundation

/// Versioned storage for on-device shadow-forecaster models.
///
/// Layout: Application Support/TrioML/model-v{N}.json, one document per model,
/// plus last-retrain-report.json describing the most recent retrain attempt
/// (including ones whose gates failed and produced no candidate).
///
/// Lifecycle: a retrain that passes its gates saves a `candidate` document.
/// Candidates do nothing until a human promotes them. Promotion retires the
/// previous promoted model (kept on disk for rollback). The bundled factory
/// model remains the fallback whenever no promoted document exists.
final class MLModelStore {
    static let shared = MLModelStore()

    enum Status: String, Codable {
        case candidate
        case promoted
        case rejected
        case retired
    }

    struct Document: Codable {
        let model: MLForecastModel
        var status: Status
        let createdAt: Date
        /// Timestamp of the newest sample the model was trained on
        let trainedThrough: Date?
        var statusChangedAt: Date?
        let evalReport: MLEvalReport?

        var versionNumber: Int { Int(model.modelVersion) ?? 0 }
    }

    private let queue = DispatchQueue(label: "MLModelStore")
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TrioML", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    // MARK: - Reads

    func allDocuments() -> [Document] {
        queue.sync { loadAll() }
    }

    /// The promoted model with the highest version, if any. Callers fall back
    /// to the bundled model when this is nil.
    func activePromotedModel() -> MLForecastModel? {
        queue.sync {
            loadAll()
                .filter { $0.status == .promoted }
                .max { $0.versionNumber < $1.versionNumber }?
                .model
        }
    }

    func pendingCandidate() -> Document? {
        queue.sync { loadAll().first { $0.status == .candidate } }
    }

    func lastRetrainReport() -> MLEvalReport? {
        queue.sync {
            guard let data = try? Data(contentsOf: reportURL) else { return nil }
            return try? JSONDecoder().decode(MLEvalReport.self, from: data)
        }
    }

    // MARK: - Writes

    /// Stores a gate-passing candidate. Any previous unreviewed candidate is
    /// superseded (marked rejected) — there is at most one pending review.
    func saveCandidate(_ document: Document) throws {
        try queue.sync {
            for var old in loadAll() where old.status == .candidate {
                old.status = .rejected
                old.statusChangedAt = Date()
                try write(old)
            }
            try write(document)
        }
    }

    func saveRetrainReport(_ report: MLEvalReport) {
        queue.sync {
            if let data = try? JSONEncoder().encode(report) {
                try? data.write(to: reportURL, options: .atomic)
            }
        }
    }

    /// Human approval: the candidate becomes the active model; the previously
    /// promoted model is retired but kept on disk for rollback.
    func promote(version: Int) throws {
        try changeStatus(of: version, from: .candidate, to: .promoted) { documents in
            for var doc in documents where doc.status == .promoted {
                doc.status = .retired
                doc.statusChangedAt = Date()
                try self.write(doc)
            }
        }
    }

    /// Human rejection: the candidate is kept on disk for the audit trail but
    /// never evaluated.
    func reject(version: Int) throws {
        try changeStatus(of: version, from: .candidate, to: .rejected)
    }

    /// Rollback: re-promote a retired model and retire the current one.
    func reactivate(version: Int) throws {
        try changeStatus(of: version, from: .retired, to: .promoted) { documents in
            for var doc in documents where doc.status == .promoted {
                doc.status = .retired
                doc.statusChangedAt = Date()
                try self.write(doc)
            }
        }
    }

    // MARK: - Internals

    private func changeStatus(
        of version: Int,
        from expected: Status,
        to newStatus: Status,
        preparing: (([Document]) throws -> Void)? = nil
    ) throws {
        try queue.sync {
            let documents = loadAll()
            guard var target = documents.first(where: { $0.versionNumber == version && $0.status == expected })
            else {
                throw NSError(
                    domain: "MLModelStore", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "no \(expected.rawValue) model v\(version)"]
                )
            }
            try preparing?(documents)
            target.status = newStatus
            target.statusChangedAt = Date()
            try write(target)
        }
    }

    private func loadAll() -> [Document] {
        let decoder = JSONDecoder()
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return urls
            .filter { $0.lastPathComponent.hasPrefix("model-v") }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Document.self, from: data)
            }
            .sorted { $0.versionNumber < $1.versionNumber }
    }

    private func write(_ document: Document) throws {
        let url = directory.appendingPathComponent("model-v\(document.versionNumber).json")
        let data = try JSONEncoder().encode(document)
        try data.write(to: url, options: .atomic)
    }

    private var reportURL: URL {
        directory.appendingPathComponent("last-retrain-report.json")
    }
}

/// The gate-suite outcome for one retrain attempt. Shown to the human reviewer;
/// persisted with each candidate for the audit trail.
struct MLEvalReport: Codable {
    struct HorizonEval: Codable {
        let candidateMAE: Double
        let persistenceMAE: Double
        let championMAE: Double?
        let sampleCount: Int
        let lowRegionCandidateMAE: Double?
        let lowRegionPersistenceMAE: Double?
        let lowRegionSampleCount: Int
    }

    struct GateResult: Codable {
        let name: String
        let passed: Bool
        let detail: String
    }

    let createdAt: Date
    let candidateVersion: Int
    let trainedOnSamples: Int
    let walkForwardDays: Int
    let horizons: [String: HorizonEval]
    let gates: [GateResult]
    let passed: Bool
    /// Data-quality flags the reviewer must see — metrics can look fine on bad data
    let invalidReadingsDropped: Int
    let skippedGap: Int
    let skippedNoDetermination: Int
}
