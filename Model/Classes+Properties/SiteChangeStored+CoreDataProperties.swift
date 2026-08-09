import CoreData
import Foundation

public extension SiteChangeStored {
    @nonobjc class func fetchRequest() -> NSFetchRequest<SiteChangeStored> {
        NSFetchRequest<SiteChangeStored>(entityName: "SiteChangeStored")
    }

    @NSManaged var date: Date?
    @NSManaged var id: UUID?
    @NSManaged var kind: String?
    @NSManaged var location: String?
    @NSManaged var note: String?
    @NSManaged var source: String?
}

extension SiteChangeStored: Identifiable {}
