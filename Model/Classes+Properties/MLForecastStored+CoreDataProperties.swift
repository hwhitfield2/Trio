import CoreData
import Foundation

public extension MLForecastStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<MLForecastStored> {
        NSFetchRequest<MLForecastStored>(entityName: "MLForecastStored")
    }

    /// Time the forecast was made
    @NSManaged var date: Date?
    /// Forecast horizon in minutes (30 or 60)
    @NSManaged var horizonMinutes: Int16
    @NSManaged var id: UUID?
    /// Version of the bundled model that produced this forecast
    @NSManaged var modelVersion: String?
    /// Predicted glucose at date + horizon (mg/dL)
    @NSManaged var predicted: Int16
}

extension MLForecastStored: Identifiable {}
