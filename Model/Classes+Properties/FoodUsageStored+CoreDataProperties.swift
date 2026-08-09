import CoreData
import Foundation

public extension FoodUsageStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<FoodUsageStored> {
        NSFetchRequest<FoodUsageStored>(entityName: "FoodUsageStored")
    }

    @NSManaged var carbs: Double
    @NSManaged var date: Date?
    @NSManaged var endedAboveRange: Bool
    @NSManaged var endGlucose: Int16
    @NSManaged var hypoWithin4h: Bool
    @NSManaged var id: UUID?
    @NSManaged var outcomeComputed: Bool
    @NSManaged var peakDelta: Int16
    @NSManaged var startGlucose: Int16
    @NSManaged var foodItem: FoodItemStored?
}

extension FoodUsageStored: Identifiable {}
