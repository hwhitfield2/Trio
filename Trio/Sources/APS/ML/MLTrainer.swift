import Foundation

/// Deterministic on-device trainer for the shadow forecaster.
///
/// Implements exact-split gradient-boosted regression trees on the delta target
/// (change from current glucose), matching the offline exporter's configuration:
/// 60 trees, depth 2, learning rate 0.03, 70% subsampling, shrinkage 0.2 folded
/// into the emitted leaf values so the existing `MLForecastModel` evaluator runs
/// the result unchanged (prediction = bg + shrunk ensemble output).
///
/// Trained models are candidates only — they do nothing until a human promotes
/// them, and even then they remain shadow-mode display models.
enum MLTrainer {
    struct Config {
        var treeCount = 60
        var maxDepth = 2
        var learningRate = 0.03
        var subsampleFraction = 0.7
        var shrinkage = 0.2
        var deltaFeature = 0
        var seed: UInt64 = 0
    }

    /// One training sample: features plus the future glucose targets.
    struct Sample {
        let date: Date
        let features: [Double]
        /// Actual glucose by horizon minutes (30, 60)
        let targets: [Int: Double]
    }

    /// Trains one ensemble per horizon on the delta target.
    /// Returns nil when there are no samples for a horizon.
    static func train(
        samples: [Sample],
        horizons: [Int] = [30, 60],
        config: Config = Config()
    ) -> [Int: MLForecastModel.Ensemble] {
        var result: [Int: MLForecastModel.Ensemble] = [:]
        for horizon in horizons {
            let usable = samples.filter { $0.targets[horizon] != nil }
            guard !usable.isEmpty else { continue }
            let features = usable.map(\.features)
            let deltas = usable.map { $0.targets[horizon]! - $0.features[config.deltaFeature] }
            result[horizon] = boost(features: features, targets: deltas, config: config, horizonSalt: UInt64(horizon))
        }
        return result
    }

    // MARK: - Gradient boosting

    private static func boost(
        features: [[Double]],
        targets: [Double],
        config: Config,
        horizonSalt: UInt64
    ) -> MLForecastModel.Ensemble {
        let sampleCount = targets.count
        let baseline = targets.reduce(0, +) / Double(sampleCount)
        var predictions = [Double](repeating: baseline, count: sampleCount)
        var rng = SplitMix64(seed: config.seed &+ horizonSalt &* 0x9E37_79B9_7F4A_7C15)
        var trees: [MLForecastModel.Tree] = []

        for _ in 0 ..< config.treeCount {
            let residuals = (0 ..< sampleCount).map { targets[$0] - predictions[$0] }
            let subsetSize = max(2, Int(Double(sampleCount) * config.subsampleFraction))
            let subset = rng.sampleWithoutReplacement(from: sampleCount, count: subsetSize)
            let tree = TreeBuilder(features: features, targets: residuals)
                .build(on: subset, maxDepth: config.maxDepth)
            for i in 0 ..< sampleCount {
                predictions[i] += config.learningRate * tree.leafValue(for: features[i])
            }
            trees.append(tree.encoded(scaledBy: config.shrinkage))
        }

        return MLForecastModel.Ensemble(
            learningRate: config.learningRate,
            baseline: baseline * config.shrinkage,
            outputOffsetFeature: config.deltaFeature,
            trees: trees
        )
    }

    // MARK: - Exact-split regression tree

    private final class TreeBuilder {
        private let features: [[Double]]
        private let targets: [Double]

        // Flat arrays in the same layout as the JSON model documents
        private var childrenLeft: [Int] = []
        private var childrenRight: [Int] = []
        private var splitFeature: [Int] = []
        private var threshold: [Double] = []
        private var value: [Double] = []

        init(features: [[Double]], targets: [Double]) {
            self.features = features
            self.targets = targets
        }

        func build(on indices: [Int], maxDepth: Int) -> BuiltTree {
            _ = grow(indices: indices, depth: maxDepth)
            return BuiltTree(
                childrenLeft: childrenLeft,
                childrenRight: childrenRight,
                feature: splitFeature,
                threshold: threshold,
                value: value
            )
        }

        /// Appends a node for the given samples and returns its index.
        private func grow(indices: [Int], depth: Int) -> Int {
            let mean = indices.reduce(0.0) { $0 + targets[$1] } / Double(indices.count)
            let node = childrenLeft.count
            childrenLeft.append(-1)
            childrenRight.append(-1)
            splitFeature.append(-2)
            threshold.append(-2)
            value.append(mean)

            guard depth > 0, indices.count >= 2,
                  let split = bestSplit(indices: indices) else { return node }

            let leftIndices = indices.filter { features[$0][split.feature] <= split.threshold }
            let rightIndices = indices.filter { features[$0][split.feature] > split.threshold }
            guard !leftIndices.isEmpty, !rightIndices.isEmpty else { return node }

            splitFeature[node] = split.feature
            threshold[node] = split.threshold
            childrenLeft[node] = grow(indices: leftIndices, depth: depth - 1)
            childrenRight[node] = grow(indices: rightIndices, depth: depth - 1)
            return node
        }

        private struct Split {
            let feature: Int
            let threshold: Double
            let gain: Double
        }

        /// Exhaustive best SSE-reduction split over all features and cut points.
        private func bestSplit(indices: [Int]) -> Split? {
            let count = Double(indices.count)
            let total = indices.reduce(0.0) { $0 + targets[$1] }
            var best: Split?

            for f in 0 ..< features[indices[0]].count {
                let sorted = indices.sorted { features[$0][f] < features[$1][f] }
                var leftSum = 0.0
                for (position, index) in sorted.enumerated().dropLast() {
                    leftSum += targets[index]
                    // Only split between distinct feature values
                    guard features[index][f] < features[sorted[position + 1]][f] else { continue }
                    let leftCount = Double(position + 1)
                    let rightCount = count - leftCount
                    let rightSum = total - leftSum
                    // SSE reduction is equivalent to maximizing sum^2/n over children
                    let gain = leftSum * leftSum / leftCount + rightSum * rightSum / rightCount
                        - total * total / count
                    if gain > (best?.gain ?? 1e-12) {
                        let cut = (features[index][f] + features[sorted[position + 1]][f]) / 2
                        best = Split(feature: f, threshold: cut, gain: gain)
                    }
                }
            }
            return best
        }
    }

    struct BuiltTree {
        let childrenLeft: [Int]
        let childrenRight: [Int]
        let feature: [Int]
        let threshold: [Double]
        let value: [Double]

        func leafValue(for sample: [Double]) -> Double {
            var node = 0
            while childrenLeft[node] != -1 {
                node = sample[feature[node]] <= threshold[node] ? childrenLeft[node] : childrenRight[node]
            }
            return value[node]
        }

        func encoded(scaledBy scale: Double) -> MLForecastModel.Tree {
            MLForecastModel.Tree(
                childrenLeft: childrenLeft,
                childrenRight: childrenRight,
                feature: feature,
                threshold: threshold,
                value: value.map { $0 * scale }
            )
        }
    }
}

/// Deterministic 64-bit RNG (SplitMix64) so retraining with identical data and
/// seed always produces an identical model.
struct SplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Fisher-Yates partial shuffle; returns `count` distinct indices in [0, n).
    mutating func sampleWithoutReplacement(from n: Int, count: Int) -> [Int] {
        var pool = Array(0 ..< n)
        let take = min(count, n)
        for i in 0 ..< take {
            let j = i + Int(next() % UInt64(n - i))
            pool.swapAt(i, j)
        }
        return Array(pool.prefix(take))
    }
}
