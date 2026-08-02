import CGMBLEKit
import Foundation
import G7SensorKit
import G7SensorKitUI
import LibreTransmitter
import LibreTransmitterUI
import LoopKit
import LoopKitUI
import Swinject

// LibreLoop (LoopKit/LibreLoop) is the FreeStyle Libre 3 / 3+ CGMManager plugin. It is not
// bundled by default: it depends on LibreCRKit, which ships extracted Abbott crypto artifacts,
// so bundling it is an explicit, legally-loaded opt-in left to the person building Trio. When
// the LibreLoop + LibreLoopUI frameworks ARE added to the workspace, this import resolves and
// the manager is registered automatically below; otherwise this whole path compiles away.
#if canImport(LibreLoop)
    import LibreLoop
#endif
#if canImport(LibreLoopUI)
    import LibreLoopUI
#endif

protocol PluginManager {
    var availableCGMManagers: [CGMManagerDescriptor] { get }
    func getCGMManagerTypeByIdentifier(_ identifier: String) -> CGMManagerUI.Type?
}

class BasePluginManager: Injectable, PluginManager {
    struct CgmPluginDescription {
        let pluginIdentifier: String
        let localizedTitle: String
        let manager: CGMManagerUI.Type
    }

    static let cgms: [CgmPluginDescription] = {
        var descriptions = [
            CgmPluginDescription(
                pluginIdentifier: G5CGMManager.pluginIdentifier,
                localizedTitle: String(localized: "Dexcom G5"),
                manager: G5CGMManager.self
            ),
            CgmPluginDescription(
                pluginIdentifier: G6CGMManager.pluginIdentifier,
                localizedTitle: String(localized: "Dexcom G6 / ONE"),
                manager: G6CGMManager.self
            ),
            CgmPluginDescription(
                pluginIdentifier: G7CGMManager.pluginIdentifier,
                localizedTitle: String(localized: "Dexcom G7 / ONE+"),
                manager: G7CGMManager.self
            ),
            CgmPluginDescription(
                pluginIdentifier: LibreTransmitterManagerV3.pluginIdentifier,
                localizedTitle: String(localized: "FreeStyle Libre"),
                manager: LibreTransmitterManagerV3.self
            )
        ]

        // Registered only when the LibreLoop framework has been added to the build. The identifier
        // and display name mirror LibreLoop's own plugin Info.plist (CGMManagerIdentifier
        // "LibreLoopCGMManager", DisplayName "FreeStyle Libre 3"). Supports Libre 3 / 3+ only.
        #if canImport(LibreLoop) && canImport(LibreLoopUI)
            descriptions.append(
                CgmPluginDescription(
                    pluginIdentifier: LibreLoopCGMManager.pluginIdentifier,
                    localizedTitle: String(localized: "FreeStyle Libre 3"),
                    manager: LibreLoopCGMManager.self
                )
            )
        #endif

        return descriptions
    }()

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    func getCGMManagerTypeByIdentifier(_ pluginIdentifier: String) -> CGMManagerUI.Type? {
        BasePluginManager.cgms.filter({ $0.pluginIdentifier == pluginIdentifier }).first?.manager
    }

    var availableCGMManagers: [CGMManagerDescriptor] {
        BasePluginManager.cgms.map { CGMManagerDescriptor(identifier: $0.pluginIdentifier, localizedTitle: $0.localizedTitle) }
    }
}
