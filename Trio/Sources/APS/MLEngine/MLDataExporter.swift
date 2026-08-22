import CoreData
import Foundation
import Swinject

/// Exports the raw event streams the ML training pipeline consumes
/// (docs/ML_DOSING_REPLACEMENT_PLAN.md Phase 1).
///
/// The export is intentionally *raw* — glucose readings, carb entries, pump
/// events, and historical determinations as they happened. Alignment into
/// 5-minute training frames, IOB decomposition, and feature engineering happen
/// in the Python side (`ml/trioml/dataset.py`) against the same versioned
/// schema, so there is exactly one place feature logic lives.
///
/// Output: one JSON Lines file, first line a metadata header, then one event
/// per line sorted by section: `{"type":"glucose"|"carbs"|"pump"|"determination",...}`.
protocol MLDataExporter {
    /// Writes the export file and returns its URL (Documents/ml_export/…jsonl).
    func exportTrainingData(daysBack: Int) async throws -> URL
}

final class BaseMLDataExporter: MLDataExporter, Injectable {
    /// Bump when the line format changes; ml/trioml/schema.py checks this.
    static let exportSchemaVersion = 1

    private let context: NSManagedObjectContext

    init(resolver: Resolver) {
        context = CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
    }

    // MARK: - Row models (Codable mirrors of the CoreData entities)

    private struct Header: Encodable {
        let type = "header"
        let schemaVersion: Int
        let exportedAt: Date
        let daysBack: Int

        private enum CodingKeys: String, CodingKey {
            case type
            case schemaVersion
            case exportedAt
            case daysBack
        }
    }

    private struct GlucoseRow: Encodable {
        let type = "glucose"
        let date: Date
        let glucose: Int
        let direction: String?
        let isManual: Bool

        private enum CodingKeys: String, CodingKey {
            case type
            case date
            case glucose
            case direction
            case isManual
        }
    }

    private struct CarbRow: Encodable {
        let type = "carbs"
        let date: Date
        let carbs: Double
        let fat: Double
        let protein: Double
        let isFPU: Bool

        private enum CodingKeys: String, CodingKey {
            case type
            case date
            case carbs
            case fat
            case protein
            case isFPU
        }
    }

    private struct PumpRow: Encodable {
        let type = "pump"
        let date: Date
        let eventType: String?
        let bolusAmount: Decimal?
        let isSMB: Bool?
        let isExternal: Bool?
        let tempBasalRate: Decimal?
        let tempBasalDurationMinutes: Int?

        private enum CodingKeys: String, CodingKey {
            case type
            case date
            case eventType
            case bolusAmount
            case isSMB
            case isExternal
            case tempBasalRate
            case tempBasalDurationMinutes
        }
    }

    private struct DeterminationRow: Encodable {
        let type = "determination"
        let date: Date
        let rate: Decimal?
        let durationMinutes: Decimal?
        let smbUnits: Decimal?
        let iob: Decimal?
        let cob: Int
        let eventualBG: Decimal?
        let insulinReq: Decimal?
        let sensitivityRatio: Decimal?
        let glucose: Decimal?
        let enacted: Bool
        /// oref's predBGs curves (mg/dL at 5-min steps from the determination
        /// time): "iob"/"zt"/"cob"/"uam", whichever the run produced. Optional
        /// and additive — older exports without it stay schema-valid — but this
        /// is what lets the training side gate a candidate against oref
        /// like-for-like instead of against eventualBG.
        let predBGs: [String: [Int]]?

        private enum CodingKeys: String, CodingKey {
            case type
            case date
            case rate
            case durationMinutes
            case smbUnits
            case iob
            case cob
            case eventualBG
            case insulinReq
            case sensitivityRatio
            case glucose
            case enacted
            case predBGs
        }
    }

    // MARK: - Export

    func exportTrainingData(daysBack: Int) async throws -> URL {
        let startDate = Date().addingTimeInterval(-Double(daysBack) * 24 * 60 * 60)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        let rows: [Data] = try await context.perform { [self] in
            var lines: [Data] = []
            lines.append(try encoder.encode(Header(
                schemaVersion: Self.exportSchemaVersion,
                exportedAt: Date(),
                daysBack: daysBack
            )))

            let glucoseRequest = GlucoseStored.fetchRequest()
            glucoseRequest.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
            glucoseRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            for reading in try context.fetch(glucoseRequest) {
                guard let date = reading.date else { continue }
                lines.append(try encoder.encode(GlucoseRow(
                    date: date,
                    glucose: Int(reading.glucose),
                    direction: reading.direction,
                    isManual: reading.isManual
                )))
            }

            let carbRequest = CarbEntryStored.fetchRequest()
            carbRequest.predicate = NSPredicate(format: "date >= %@", startDate as NSDate)
            carbRequest.sortDescriptors = [NSSortDescriptor(key: "date", ascending: true)]
            for entry in try context.fetch(carbRequest) {
                guard let date = entry.date else { continue }
                lines.append(try encoder.encode(CarbRow(
                    date: date,
                    carbs: entry.carbs,
                    fat: entry.fat,
                    protein: entry.protein,
                    isFPU: entry.isFPU
                )))
            }

            let pumpRequest = PumpEventStored.fetchRequest()
            pumpRequest.predicate = NSPredicate(format: "timestamp >= %@", startDate as NSDate)
            pumpRequest.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            pumpRequest.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
            for event in try context.fetch(pumpRequest) {
                guard let date = event.timestamp else { continue }
                lines.append(try encoder.encode(PumpRow(
                    date: date,
                    eventType: event.type,
                    bolusAmount: event.bolus?.amount?.decimalValue,
                    isSMB: event.bolus.map(\.isSMB),
                    isExternal: event.bolus.map(\.isExternal),
                    tempBasalRate: event.tempBasal?.rate?.decimalValue,
                    tempBasalDurationMinutes: event.tempBasal.map { Int($0.duration) }
                )))
            }

            let determinationRequest = OrefDetermination.fetchRequest()
            determinationRequest.predicate = NSPredicate(format: "deliverAt >= %@", startDate as NSDate)
            determinationRequest.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
            determinationRequest.relationshipKeyPathsForPrefetching = ["forecasts.forecastValues"]
            for determination in try context.fetch(determinationRequest) {
                guard let date = determination.deliverAt else { continue }
                var predBGs: [String: [Int]] = [:]
                for forecast in determination.forecasts ?? [] {
                    guard let type = forecast.type else { continue }
                    predBGs[type] = forecast.forecastValuesArray.map { Int($0.value) }
                }
                lines.append(try encoder.encode(DeterminationRow(
                    date: date,
                    rate: determination.rate?.decimalValue,
                    durationMinutes: determination.duration?.decimalValue,
                    smbUnits: determination.smbToDeliver?.decimalValue,
                    iob: determination.iob?.decimalValue,
                    cob: Int(determination.cob),
                    eventualBG: determination.eventualBG?.decimalValue,
                    insulinReq: determination.insulinReq?.decimalValue,
                    sensitivityRatio: determination.sensitivityRatio?.decimalValue,
                    glucose: determination.glucose?.decimalValue,
                    enacted: determination.enacted,
                    predBGs: predBGs.isEmpty ? nil : predBGs
                )))
            }

            return lines
        }

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let exportDirectory = documents.appendingPathComponent("ml_export", isDirectory: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = exportDirectory.appendingPathComponent("trio-training-export-\(formatter.string(from: Date())).jsonl")

        var output = Data()
        for row in rows {
            output.append(row)
            output.append(Data("\n".utf8))
        }
        try output.write(to: url, options: .atomic)

        debug(.apsManager, "MLDataExporter: wrote \(rows.count - 1) events to \(url.lastPathComponent)")
        return url
    }
}
