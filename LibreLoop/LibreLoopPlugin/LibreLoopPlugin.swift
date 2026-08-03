import Foundation
import LoopKitUI
import LibreLoop
import LibreLoopUI

public final class LibreLoopPlugin: NSObject, CGMManagerUIPlugin {
    public var cgmManagerType: CGMManagerUI.Type? { LibreLoopCGMManager.self }
    public var pumpManagerType: PumpManagerUI.Type? { nil }

    public override init() {
        super.init()
    }
}
