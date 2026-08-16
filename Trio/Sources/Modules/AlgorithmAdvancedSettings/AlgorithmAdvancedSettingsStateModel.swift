import Combine
import LoopKit
import Observation
import SwiftUI

extension AlgorithmAdvancedSettings {
    final class StateModel: BaseStateModel<Provider> {
        @Injected() var settings: SettingsManager!
        @Injected() var storage: FileStorage!
        @Injected() var nightscout: NightscoutManager!
        @Injected() private var tidepoolManager: TidepoolManager!

        var units: GlucoseUnits = .mgdL

        @Published var maxDailySafetyMultiplier: Decimal = 3
        @Published var currentBasalSafetyMultiplier: Decimal = 4
        @Published var useCustomPeakTime: Bool = false
        @Published var insulinPeakTime: Decimal = 75
        @Published var skipNeutralTemps: Bool = false
        @Published var unsuspendIfNoTemp: Bool = false
        @Published var min5mCarbimpact: Decimal = 8
        @Published var remainingCarbsFraction: Decimal = 1.0
        @Published var remainingCarbsCap: Decimal = 90
        @Published var noisyCGMTargetMultiplier: Decimal = 1.3
        @Published var insulinActionCurve: Decimal = 10
        @Published var smbDeliveryRatio: Decimal = 0.5
        @Published var smbInterval: Decimal = 3
        @Published var insulinTypeSelection: InsulinTypeSelection = .automatic

        /// What "Automatic" currently resolves to, so the picker can say so
        /// rather than leaving the user to guess.
        ///
        /// `provider` is nil until `configureView()` sets the resolver on
        /// `.onAppear`, and SwiftUI evaluates `body` before that — so this is
        /// read once with no provider behind it. Falling back to `.automatic`
        /// costs one frame of a less specific footer; force-unwrapping crashes
        /// the screen.
        var pumpReportedInsulinType: InsulinTypeSelection {
            guard let provider else { return .automatic }
            return InsulinTypeSelection(pumpInsulinType: provider.pumpInsulinType)
        }

        /// How to name what the pump reports. Kept separate from
        /// `pumpReportedInsulinType` so "the pump has told us nothing" reads as
        /// itself, rather than echoing the word "Automatic" back at the user.
        var pumpReportedInsulinTypeDescription: String {
            let reported = pumpReportedInsulinType
            guard reported != .automatic else {
                return String(localized: "not reported", comment: "The pump has not reported an insulin type")
            }
            return reported.displayName
        }

        var pumpSettings: PumpSettings {
            provider.settings()
        }

        override func subscribe() {
            units = settingsManager.settings.units

            subscribePreferencesSetting(\.maxDailySafetyMultiplier, on: $maxDailySafetyMultiplier) {
                maxDailySafetyMultiplier = $0 }
            subscribePreferencesSetting(\.currentBasalSafetyMultiplier, on: $currentBasalSafetyMultiplier) {
                currentBasalSafetyMultiplier = $0 }
            subscribePreferencesSetting(\.useCustomPeakTime, on: $useCustomPeakTime) { useCustomPeakTime = $0 }
            subscribePreferencesSetting(\.insulinPeakTime, on: $insulinPeakTime) { insulinPeakTime = $0 }
            subscribePreferencesSetting(\.skipNeutralTemps, on: $skipNeutralTemps) { skipNeutralTemps = $0 }
            subscribePreferencesSetting(\.unsuspendIfNoTemp, on: $unsuspendIfNoTemp) { unsuspendIfNoTemp = $0 }
            subscribePreferencesSetting(\.min5mCarbimpact, on: $min5mCarbimpact) { min5mCarbimpact = $0 }
            subscribePreferencesSetting(\.remainingCarbsFraction, on: $remainingCarbsFraction) { remainingCarbsFraction = $0 }
            subscribePreferencesSetting(\.remainingCarbsCap, on: $remainingCarbsCap) { remainingCarbsCap = $0 }
            subscribePreferencesSetting(\.noisyCGMTargetMultiplier, on: $noisyCGMTargetMultiplier) {
                noisyCGMTargetMultiplier = $0 }
            subscribePreferencesSetting(\.smbDeliveryRatio, on: $smbDeliveryRatio) { smbDeliveryRatio = $0 }
            subscribePreferencesSetting(\.smbInterval, on: $smbInterval) { smbInterval = $0 }

            // The stored setting is the insulin *type*; the curve oref actually
            // doses against is derived from it, so re-resolve on every change.
            subscribeSetting(\.insulinTypeSelection, on: $insulinTypeSelection, initial: {
                insulinTypeSelection = $0
            }, didSet: { [weak self] _ in
                guard let self else { return }
                settingsManager.updateInsulinCurve(provider.pumpInsulinType)
            })

            insulinActionCurve = pumpSettings.insulinActionCurve
        }

        var isPumpSettingUnchanged: Bool {
            pumpSettings.insulinActionCurve == insulinActionCurve
        }

        func saveIfChanged() {
            if !isPumpSettingUnchanged {
                let settings = PumpSettings(
                    insulinActionCurve: insulinActionCurve,
                    maxBolus: pumpSettings.maxBolus,
                    maxBasal: pumpSettings.maxBasal
                )
                provider.save(settings: settings)
                    .receive(on: DispatchQueue.main)
                    .sink { _ in
                        let settings = self.provider.settings()
                        self.insulinActionCurve = settings.insulinActionCurve

                        Task.detached(priority: .low) {
                            do {
                                debug(.nightscout, "Attempting to upload DIA to Nightscout")
                                try await self.nightscout.uploadProfiles()
                            } catch {
                                debug(
                                    .default,
                                    "\(DebuggingIdentifiers.failed) failed to upload DIA to Nightscout: \(error)"
                                )
                            }
                        }

                        Task.detached(priority: .low) {
                            await self.tidepoolManager.uploadSettings()
                        }
                    } receiveValue: {}
                    .store(in: &lifetime)
            }
        }
    }
}

extension AlgorithmAdvancedSettings.StateModel: SettingsObserver {
    func settingsDidChange(_: TrioSettings) {
        units = settingsManager.settings.units
    }
}
