import CoreData
import Foundation

public extension FoodItemStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<FoodItemStored> {
        NSFetchRequest<FoodItemStored>(entityName: "FoodItemStored")
    }

    @NSManaged var carbs: NSDecimalNumber?
    @NSManaged var createdAt: Date?
    @NSManaged var fat: NSDecimalNumber?
    @NSManaged var id: UUID?
    @NSManaged var lastUsedAt: Date?
    @NSManaged var name: String?
    @NSManaged var normalizedName: String?
    @NSManaged var protein: NSDecimalNumber?
    @NSManaged var source: String?
    @NSManaged var useCount: Int32
    @NSManaged var usages: Set<FoodUsageStored>?
}

// MARK: Generated accessors for usages

public extension FoodItemStored {
    @objc(addUsagesObject:)
    @NSManaged func addToUsages(_ value: FoodUsageStored)

    @objc(removeUsagesObject:)
    @NSManaged func removeFromUsages(_ value: FoodUsageStored)

    @objc(addUsages:)
    @NSManaged func addToUsages(_ values: NSSet)

    @objc(removeUsages:)
    @NSManaged func removeFromUsages(_ values: NSSet)
}

extension FoodItemStored: Identifiable {}
