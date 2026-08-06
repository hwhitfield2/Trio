import Foundation
import LoopKit

struct CarbsEntry: JSON, Equatable, Hashable, Identifiable {
    let id: String?
    let createdAt: Date
    let actualDate: Date?
    let carbs: Decimal
    let fat: Decimal?
    let protein: Decimal?
    let note: String?
    let enteredBy: String?
    let isFPU: Bool?
    let fpuID: String?
    /// Estimated carb absorption duration in hours (e.g. from the AI meal analysis).
    /// When longer than the ~3 hours oref's carb model assumes, storage spreads part
    /// of the entry into future-dated carb equivalents so the algorithm's COB decays
    /// over this duration. Nil = absorb normally.
    let absorptionHours: Decimal?

    init(
        id: String?,
        createdAt: Date,
        actualDate: Date?,
        carbs: Decimal,
        fat: Decimal?,
        protein: Decimal?,
        note: String?,
        enteredBy: String?,
        isFPU: Bool?,
        fpuID: String?,
        absorptionHours: Decimal? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.actualDate = actualDate
        self.carbs = carbs
        self.fat = fat
        self.protein = protein
        self.note = note
        self.enteredBy = enteredBy
        self.isFPU = isFPU
        self.fpuID = fpuID
        self.absorptionHours = absorptionHours
    }

    static let local = "Trio"
    static let appleHealth = "applehealth"

    static func == (lhs: CarbsEntry, rhs: CarbsEntry) -> Bool {
        lhs.createdAt == rhs.createdAt
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(createdAt)
    }
}

extension CarbsEntry {
    private enum CodingKeys: String, CodingKey {
        case id = "_id"
        case createdAt = "created_at"
        case actualDate
        case carbs
        case fat
        case protein
        case note = "notes"
        case enteredBy
        case isFPU
        case fpuID
        case absorptionHours
    }
}

extension CarbsEntry {
    func convertSyncCarb(operation: LoopKit.Operation = .create) -> SyncCarbObject {
        SyncCarbObject(
            absorptionTime: nil,
            createdByCurrentApp: true,
            foodType: nil,
            grams: Double(carbs),
            startDate: createdAt,
            uuid: UUID(uuidString: id!),
            provenanceIdentifier: enteredBy ?? "Trio",
            syncIdentifier: id,
            syncVersion: nil,
            userCreatedDate: nil,
            userUpdatedDate: nil,
            userDeletedDate: nil,
            operation: operation,
            addedDate: nil,
            supercededDate: nil
        )
    }
}
