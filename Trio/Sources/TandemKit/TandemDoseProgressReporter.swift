import Foundation
import LoopKit

/// Time-based bolus progress estimate; actual completion is confirmed by
/// polling the pump's last-bolus status.
final class TandemDoseProgressReporter: DoseProgressTimerEstimator {
    private let pumpManager: TandemPumpManager
    private let units: Double
    private let startDate: Date
    private let estimatedDuration: TimeInterval

    override var progress: DoseProgress {
        let elapsed = -startDate.timeIntervalSinceNow
        let percentComplete = min(max(elapsed / estimatedDuration, 0), 1)
        let delivered = pumpManager.roundToSupportedBolusVolume(units: percentComplete * units)
        return DoseProgress(deliveredUnits: delivered, percentComplete: percentComplete)
    }

    init(
        pumpManager: TandemPumpManager,
        units: Double,
        startDate: Date,
        estimatedDuration: TimeInterval,
        reportingQueue: DispatchQueue
    ) {
        self.pumpManager = pumpManager
        self.units = units
        self.startDate = startDate
        self.estimatedDuration = max(estimatedDuration, 1)
        super.init(reportingQueue: reportingQueue)
    }

    override func timerParameters() -> (delay: TimeInterval, repeating: TimeInterval) {
        let timeBetweenPulses = TimeInterval(2)
        let timeSinceStart = startDate.timeIntervalSinceNow
        let delayUntilNextPulse = timeBetweenPulses - timeSinceStart.remainder(dividingBy: timeBetweenPulses)
        return (delay: delayUntilNextPulse, repeating: timeBetweenPulses)
    }
}
