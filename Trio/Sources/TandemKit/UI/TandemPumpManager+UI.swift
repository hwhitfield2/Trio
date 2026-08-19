import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

extension TandemPumpManager: PumpManagerUI {
    static func setupViewController(
        initialSettings _: PumpManagerSetupSettings,
        bluetoothProvider _: any BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        prefersToSkipUserInteraction _: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> SetupUIResult<any PumpManagerViewController, any PumpManagerUI> {
        let coordinator = TandemUICoordinator(
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
        return .userInteractionRequired(coordinator)
    }

    func settingsViewController(
        bluetoothProvider _: BluetoothProvider,
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool,
        allowedInsulinTypes: [InsulinType]
    ) -> PumpManagerViewController {
        TandemUICoordinator(
            pumpManager: self,
            colorPalette: colorPalette,
            allowedInsulinTypes: allowedInsulinTypes
        )
    }

    func deliveryUncertaintyRecoveryViewController(
        colorPalette: LoopUIColorPalette,
        allowDebugFeatures _: Bool
    ) -> (UIViewController & CompletionNotifying) {
        TandemUICoordinator(pumpManager: self, colorPalette: colorPalette, allowedInsulinTypes: [])
    }

    func hudProvider(
        bluetoothProvider _: BluetoothProvider,
        colorPalette _: LoopUIColorPalette,
        allowedInsulinTypes _: [InsulinType]
    ) -> HUDProvider? {
        nil
    }

    static func createHUDView(rawValue _: [String: Any]) -> BaseHUDView? {
        nil
    }

    static var onboardingImage: UIImage? {
        UIImage(systemName: "externaldrive.connected.to.line.below")
    }

    var smallImage: UIImage? {
        UIImage(systemName: "externaldrive.connected.to.line.below")
    }

    /// What Trio's home screen says about this pump when there is something to
    /// say.
    ///
    /// It comes from the same ranked headline the pump screen shows, so the two
    /// can never disagree — the home screen used to report a suspend while the
    /// unacknowledged alarm that caused it was invisible everywhere. An alarm
    /// reports its own name rather than the word "alarm": in a hundred-point
    /// column, "Empty Cartridge" is worth more than a severity.
    var pumpStatusHighlight: DeviceStatusHighlight? {
        let headline = state.headlineStatus
        let message = state.activeAlarmNames ?? headline.title
        switch headline.tone {
        case .critical:
            return PumpStatusHighlight(
                localizedMessage: message,
                imageName: headline.symbolName,
                state: .critical
            )
        case .caution:
            return PumpStatusHighlight(
                localizedMessage: message,
                imageName: headline.symbolName,
                state: .warning
            )
        case .ok,
             .info,
             .idle:
            return nil
        }
    }

    var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }

    var pumpStatusBadge: DeviceStatusBadge? { nil }
}
