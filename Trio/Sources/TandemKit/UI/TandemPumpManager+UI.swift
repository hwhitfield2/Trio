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

    var pumpStatusHighlight: DeviceStatusHighlight? {
        if state.pairingCode.isEmpty {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Not Paired"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }
        if state.suspended {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Insulin Suspended"),
                imageName: "pause.circle.fill",
                state: .warning
            )
        }
        if state.lastSync != .distantPast, Date.now.timeIntervalSince(state.lastSync) > .minutes(12) {
            return PumpStatusHighlight(
                localizedMessage: String(localized: "Signal Loss"),
                imageName: "exclamationmark.circle.fill",
                state: .critical
            )
        }
        return nil
    }

    var pumpLifecycleProgress: DeviceLifecycleProgress? { nil }

    var pumpStatusBadge: DeviceStatusBadge? { nil }
}
