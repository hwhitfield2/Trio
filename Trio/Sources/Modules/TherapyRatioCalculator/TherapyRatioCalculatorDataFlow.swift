import Foundation

enum TherapyRatioCalculator {
    enum Config {}
}

protocol TherapyRatioCalculatorProvider: Provider {
    var isfProfile: InsulinSensitivities { get }
    var carbRatios: CarbRatios { get }
    func saveISFProfile(_ profile: InsulinSensitivities)
    func saveCarbRatios(_ profile: CarbRatios)
}
