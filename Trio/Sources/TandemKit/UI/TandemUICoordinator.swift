import LoopKit
import LoopKitUI
import SwiftUI
import UIKit

enum TandemUIScreen {
    case pairing
    case settings
}

/// Hosts the TandemKit setup and settings SwiftUI screens and reports
/// onboarding lifecycle events back to Trio.
final class TandemUICoordinator: UINavigationController, PumpManagerOnboarding, CompletionNotifying {
    private let colorPalette: LoopUIColorPalette
    private var pumpManager: TandemPumpManager
    private let allowedInsulinTypes: [InsulinType]

    weak var pumpManagerOnboardingDelegate: (any PumpManagerOnboardingDelegate)?
    weak var completionDelegate: (any CompletionDelegate)?

    init(
        pumpManager: TandemPumpManager? = nil,
        colorPalette: LoopUIColorPalette,
        allowedInsulinTypes: [InsulinType]
    ) {
        self.pumpManager = pumpManager ?? TandemPumpManager(state: TandemPumpState())
        self.colorPalette = colorPalette
        self.allowedInsulinTypes = allowedInsulinTypes
        super.init(navigationBarClass: UINavigationBar.self, toolbarClass: UIToolbar.self)
    }

    @available(*, unavailable) required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationBar.prefersLargeTitles = true

        let initialScreen: TandemUIScreen = pumpManager.isOnboarded ? .settings : .pairing
        setViewControllers([viewController(for: initialScreen)], animated: false)
    }

    private func viewController(for screen: TandemUIScreen) -> UIViewController {
        switch screen {
        case .pairing:
            let viewModel = TandemPairingViewModel(
                pumpManager: pumpManager,
                allowedInsulinTypes: allowedInsulinTypes
            )
            viewModel.didFinish = { [weak self] in
                guard let self = self else { return }
                self.pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didCreatePumpManager: self.pumpManager)
                self.pumpManagerOnboardingDelegate?.pumpManagerOnboarding(didOnboardPumpManager: self.pumpManager)
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
            viewModel.didCancel = { [weak self] in
                guard let self = self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
            return UIHostingController(rootView: TandemPairingView(viewModel: viewModel))
        case .settings:
            let viewModel = TandemSettingsViewModel(pumpManager: pumpManager)
            viewModel.didFinish = { [weak self] in
                guard let self = self else { return }
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
            viewModel.didDeletePump = { [weak self] in
                guard let self = self else { return }
                self.pumpManager.deletePump()
                self.completionDelegate?.completionNotifyingDidComplete(self)
            }
            return UIHostingController(rootView: TandemSettingsView(viewModel: viewModel))
        }
    }
}
