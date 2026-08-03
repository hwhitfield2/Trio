import HealthKit

// LoopKit's HKUnit extensions are internal-scoped, so each plugin redeclares
// the units it needs. Matches the pattern in G7SensorKit/Common/HKUnit.swift.
extension HKUnit {
    static let milligramsPerDeciliter: HKUnit = HKUnit.gramUnit(with: .milli).unitDivided(by: .literUnit(with: .deci))
    static let milligramsPerDeciliterPerMinute: HKUnit = milligramsPerDeciliter.unitDivided(by: .minute())
}
