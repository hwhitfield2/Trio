import Foundation
import Testing

@testable import Trio

@Suite("ML Forecaster Tests") struct MLForecasterTests {
    /// The bundled model ships in the app bundle's json folder reference;
    /// fall back to the test bundle so the suite also works unhosted.
    private func loadModel() throws -> MLForecastModel {
        let url = Bundle.main.url(forResource: "json/defaults/TrioMLForecaster", withExtension: "json")
            ?? Bundle(for: BundleReference.self).url(forResource: "TrioMLForecaster", withExtension: "json")
        let unwrapped = try #require(url, "TrioMLForecaster.json not found in app or test bundle")
        return try JSONDecoder().decode(MLForecastModel.self, from: Data(contentsOf: unwrapped))
    }

    private struct Fixtures: Decodable {
        struct Case: Decodable {
            let horizon: Int
            let features: [Double]
            let expected: Double
        }

        let modelVersion: String
        let cases: [Case]
    }

    @Test("Bundled model decodes with both horizons") func testModelDecodes() throws {
        let model = try loadModel()
        #expect(model.horizons["30"] != nil)
        #expect(model.horizons["60"] != nil)
        #expect(model.featureNames.count == 13)
        #expect(model.horizons["30"]!.trees.isEmpty == false)
    }

    @Test("Evaluator reproduces Python-pinned predictions") func testEvaluatorMatchesFixtures() throws {
        let model = try loadModel()
        let testBundle = Bundle(for: BundleReference.self)
        let path = try #require(testBundle.path(forResource: "MLForecasterFixtures", ofType: "json"))
        let fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: URL(filePath: path)))

        #expect(fixtures.modelVersion == model.modelVersion)
        #expect(fixtures.cases.isEmpty == false)

        for testCase in fixtures.cases {
            let predicted = try #require(
                model.predict(features: testCase.features, horizonMinutes: testCase.horizon),
                "prediction returned nil for horizon \(testCase.horizon)"
            )
            #expect(
                abs(predicted - testCase.expected) < 0.01,
                "horizon \(testCase.horizon): predicted \(predicted), expected \(testCase.expected)"
            )
        }
    }

    @Test("Unknown horizon and malformed input return nil") func testEvaluatorRejectsBadInput() throws {
        let model = try loadModel()
        let features = [Double](repeating: 0, count: model.featureNames.count)
        #expect(model.predict(features: features, horizonMinutes: 45) == nil)
        #expect(model.predict(features: [1, 2, 3], horizonMinutes: 30) == nil)
    }
}
