import Foundation
import Testing

@testable import Trio

@Suite("ML Trainer Tests") struct MLTrainerTests {
    /// Synthetic learnable dataset: the future delta depends on the trend and
    /// IOB features with mild deterministic noise, so a working trainer must
    /// beat persistence on it.
    private func syntheticSamples(count: Int) -> [MLTrainer.Sample] {
        var rng = SplitMix64(seed: 42)
        var samples: [MLTrainer.Sample] = []
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< count {
            func unit() -> Double { Double(rng.next() % 1000) / 1000.0 }
            let bg = 90 + unit() * 140
            let trend = (unit() - 0.5) * 20
            let iob = unit() * 0.4
            let noise = (unit() - 0.5) * 6
            var features = [Double](repeating: 0, count: MLForecastService.featureNames.count)
            features[0] = bg
            features[1] = trend / 3
            features[2] = trend / 1.5
            features[3] = trend
            features[4] = iob
            let delta30 = trend * 1.2 - iob * 40 + noise
            samples.append(MLTrainer.Sample(
                date: start.addingTimeInterval(Double(i) * 300),
                features: features,
                targets: [30: bg + delta30, 60: bg + delta30 * 1.8]
            ))
        }
        return samples
    }

    @Test("Training is deterministic") func testDeterminism() throws {
        let samples = syntheticSamples(count: 300)
        let a = MLTrainer.train(samples: samples)
        let b = MLTrainer.train(samples: samples)
        let probe = syntheticSamples(count: 40)
        for horizon in [30, 60] {
            let modelA = try #require(a[horizon])
            let modelB = try #require(b[horizon])
            #expect(modelA.baseline == modelB.baseline)
            #expect(modelA.trees.count == modelB.trees.count)
            for sample in probe {
                #expect(evaluate(modelA, sample.features) == evaluate(modelB, sample.features))
            }
        }
    }

    @Test("Learns synthetic signal and beats persistence") func testBeatsPersistenceOnLearnableData() throws {
        let all = syntheticSamples(count: 500)
        let train = Array(all.prefix(400))
        let test = Array(all.suffix(100))
        let ensembles = MLTrainer.train(samples: train)
        let ensemble = try #require(ensembles[30])

        var modelError = 0.0, persistenceError = 0.0
        for sample in test {
            let target = try #require(sample.targets[30])
            let modelPrediction = evaluate(ensemble, sample.features)
            modelError += abs(modelPrediction - target)
            persistenceError += abs(sample.features[0] - target)
        }
        #expect(
            modelError < persistenceError,
            "model MAE \(modelError / 100) should beat persistence \(persistenceError / 100)"
        )
    }

    @Test("Ensemble JSON round-trip preserves predictions") func testRoundTrip() throws {
        let samples = syntheticSamples(count: 200)
        let ensembles = MLTrainer.train(samples: samples)
        let model = MLForecastModel(
            modelVersion: "test",
            trainedOnSamples: samples.count,
            featureNames: MLForecastService.featureNames,
            horizons: Dictionary(uniqueKeysWithValues: ensembles.map { (String($0.key), $0.value) })
        )
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(MLForecastModel.self, from: data)
        for sample in syntheticSamples(count: 30) {
            for horizon in [30, 60] {
                #expect(
                    model.predict(features: sample.features, horizonMinutes: horizon)
                        == decoded.predict(features: sample.features, horizonMinutes: horizon)
                )
            }
        }
    }

    @Test("Gates fail closed on insufficient data") func testGatesFailClosed() {
        let evaluation = MLRetrainService.Evaluation(
            days: 2,
            horizons: [
                "30": MLEvalReport.HorizonEval(
                    candidateMAE: 10, persistenceMAE: 12, championMAE: nil, sampleCount: 50,
                    lowRegionCandidateMAE: nil, lowRegionPersistenceMAE: nil, lowRegionSampleCount: 0
                )
            ],
            championComparisonSamples: 0
        )
        let (gates, passed) = MLRetrainService.applyGates(evaluation: evaluation)
        #expect(passed == false)
        #expect(gates.contains { $0.name == "minimum_samples" && !$0.passed })
        #expect(gates.contains { $0.name == "minimum_days" && !$0.passed })
    }

    /// Evaluates an ensemble the same way MLForecastModel.predict does,
    /// including the delta-offset feature.
    private func evaluate(_ ensemble: MLForecastModel.Ensemble, _ features: [Double]) -> Double {
        var total = ensemble.baseline
        if let offset = ensemble.outputOffsetFeature {
            total += features[offset]
        }
        for tree in ensemble.trees {
            var node = 0
            while tree.childrenLeft[node] != -1 {
                node = features[tree.feature[node]] <= tree.threshold[node]
                    ? tree.childrenLeft[node]
                    : tree.childrenRight[node]
            }
            total += ensemble.learningRate * tree.value[node]
        }
        return total
    }
}
