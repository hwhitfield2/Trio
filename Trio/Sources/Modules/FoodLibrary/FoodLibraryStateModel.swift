import CoreData
import Foundation
import Observation
import SwiftUI

extension FoodLibrary {
    enum SortOrder: String, CaseIterable, Identifiable {
        case recent
        case frequent
        case name

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .recent: return String(localized: "Recent")
            case .frequent: return String(localized: "Frequent")
            case .name: return String(localized: "Name")
            }
        }
    }

    @Observable final class StateModel: BaseStateModel<Provider> {
        @ObservationIgnored @Injected() var foodLibraryManager: FoodLibraryManager!

        var units: GlucoseUnits = .mgdL
        var searchText = ""
        var sortOrder: SortOrder = .recent
        var importedCount = 0
        var showImportAlert = false

        let viewContext = CoreDataStack.shared.persistentContainer.viewContext

        override func subscribe() {
            units = settingsManager.settings.units
            Task {
                await foodLibraryManager.computePendingOutcomes()
            }
        }

        @MainActor func importPresets() async {
            importedCount = await foodLibraryManager.importMealPresets()
            showImportAlert = true
        }

        @MainActor func delete(_ item: FoodItemStored) {
            viewContext.delete(item)
            do {
                guard viewContext.hasChanges else { return }
                try viewContext.save()
            } catch {
                debug(.coreData, "\(DebuggingIdentifiers.failed) Failed to delete food item: \(error)")
            }
        }
    }
}
