import CoreData
import Foundation

/// Builds historical training samples from Core Data for on-device retraining.
///
/// Mirrors the offline pipeline (ml/train.py build_samples) exactly: one sample
/// per CGM reading, features from data available at that moment, targets from
/// the readings 30/60 minutes later. Samples are dropped rather than built from
/// gaps, stale determinations, or physiologically invalid readings.
enum MLSampleBuilder {
    /// Same constants as MLForecastService.TrainingParity and ml/train.py
    static let cgmTolerance: TimeInterval = 6 * 60
    static let targetTolerance: TimeInterval = 10 * 60
    static let determinationMaxAge: TimeInterval = 30 * 60
    static let carbEntryLookback = 8
    /// Readings below the CGM reporting floor are dying-sensor artifacts
    static let minValidGlucose = 39
    /// Matches the extended Core Data retention for training-relevant entities
    static let historyDays = 365

    struct Result {
        let samples: [MLTrainer.Sample]
        var skippedGap = 0
        var skippedNoDetermination = 0
        var skippedNoTarget = 0
        var invalidReadingsDropped = 0
    }

    static func buildSamples(context: NSManagedObjectContext) async throws -> Result {
        let now = Date()
        let start = now.addingTimeInterval(-Double(historyDays) * 24 * 3600)

        async let glucoseResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: GlucoseStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@ AND isManual == NO", start as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "glucose"]
        )
        async let determinationResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: OrefDetermination.self,
            onContext: context,
            predicate: NSPredicate(format: "deliverAt >= %@", start as NSDate),
            key: "deliverAt",
            ascending: true,
            propertiesToFetch: ["deliverAt", "iob", "cob", "sensitivityRatio"]
        )
        async let pumpEventResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: PumpEventStored.self,
            onContext: context,
            predicate: NSPredicate(format: "timestamp >= %@", start as NSDate),
            key: "timestamp",
            ascending: true,
            relationshipKeyPathsForPrefetching: ["tempBasal"]
        )
        async let carbResult = CoreDataStack.shared.fetchEntitiesAsync(
            ofType: CarbEntryStored.self,
            onContext: context,
            predicate: NSPredicate(format: "date >= %@", start as NSDate),
            key: "date",
            ascending: true,
            propertiesToFetch: ["date", "carbs"]
        )

        let (glucoseDicts, detDicts, pumpEvents, carbDicts) =
            try await (glucoseResult, determinationResult, pumpEventResult, carbResult)

        return await context.perform {
            var result = Result(samples: [])

            var readings: [(date: Date, glucose: Double)] = []
            for dict in glucoseDicts as? [[String: Any]] ?? [] {
                guard let date = dict["date"] as? Date, let glucose = dict["glucose"] as? Int16 else { continue }
                if glucose < minValidGlucose {
                    result.invalidReadingsDropped += 1
                    continue
                }
                readings.append((date, Double(glucose)))
            }
            guard readings.count > 20 else { return result }
            let readingTimes = readings.map(\.date.timeIntervalSince1970)

            struct Det { let ts: TimeInterval
                let iob: Double
                let cob: Double
                let sens: Double }
            let dets: [Det] = (detDicts as? [[String: Any]] ?? []).compactMap { dict in
                guard let date = dict["deliverAt"] as? Date else { return nil }
                return Det(
                    ts: date.timeIntervalSince1970,
                    iob: (dict["iob"] as? NSDecimalNumber).map { Double(truncating: $0) } ?? 0,
                    cob: (dict["cob"] as? Int16).map(Double.init) ?? 0,
                    sens: (dict["sensitivityRatio"] as? NSDecimalNumber).map { Double(truncating: $0) } ?? 1.0
                )
            }
            let detTimes = dets.map(\.ts)

            // Delivered-basal segments from temp basals and suspend/resume pairs
            var segments: [(start: TimeInterval, end: TimeInterval, rate: Double)] = []
            var suspendStart: TimeInterval?
            for event in pumpEvents as? [PumpEventStored] ?? [] {
                guard let timestamp = event.timestamp?.timeIntervalSince1970 else { continue }
                switch event.type {
                case PumpEventStored.EventType.tempBasal.rawValue:
                    if let temp = event.tempBasal {
                        let rate = temp.rate.map { Double(truncating: $0) } ?? 0
                        segments.append((timestamp, timestamp + Double(temp.duration) * 60, rate))
                    }
                case PumpEventStored.EventType.pumpSuspend.rawValue:
                    suspendStart = timestamp
                case PumpEventStored.EventType.pumpResume.rawValue:
                    if let start = suspendStart {
                        segments.append((start, timestamp, 0))
                        suspendStart = nil
                    }
                default:
                    break
                }
            }
            segments.sort { $0.start < $1.start }
            let segmentStarts = segments.map(\.start)

            func rate(at t: TimeInterval) -> Double {
                var current = 0.0
                // Segments never outlast ~2h; scan the window that could cover t
                var i = Self.bisectRight(segmentStarts, t) - 1
                let horizon = t - 3 * 3600
                var latestStart = -Double.greatestFiniteMagnitude
                while i >= 0, segments[i].start >= horizon {
                    if segments[i].start <= t, t < segments[i].end, segments[i].start > latestStart {
                        current = segments[i].rate
                        latestStart = segments[i].start
                    }
                    i -= 1
                }
                return current
            }

            func deliveredUnits(from: TimeInterval, to: TimeInterval) -> Double {
                var total = 0.0
                var cursor = from
                while cursor < to {
                    let span = min(300, to - cursor)
                    total += rate(at: cursor) * span / 3600.0
                    cursor += span
                }
                return total
            }

            let carbs: [(ts: TimeInterval, grams: Double)] = (carbDicts as? [[String: Any]] ?? [])
                .compactMap { dict in
                    guard let date = dict["date"] as? Date else { return nil }
                    return (date.timeIntervalSince1970, dict["carbs"] as? Double ?? 0)
                }
            let carbTimes = carbs.map(\.ts)

            func nearestReading(to t: TimeInterval, tolerance: TimeInterval) -> Double? {
                let i = Self.bisectLeft(readingTimes, t)
                var best: (interval: TimeInterval, glucose: Double)?
                for candidate in [i - 1, i] where candidate >= 0 && candidate < readings.count {
                    let interval = abs(readingTimes[candidate] - t)
                    if interval <= tolerance, best == nil || interval < best!.interval {
                        best = (interval, readings[candidate].glucose)
                    }
                }
                return best?.glucose
            }

            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let nowTs = now.timeIntervalSince1970

            var samples: [MLTrainer.Sample] = []
            for (index, reading) in readings.enumerated() {
                let t = readingTimes[index]
                let bg = reading.glucose

                guard let bg5 = nearestReading(to: t - 5 * 60, tolerance: cgmTolerance),
                      let bg15 = nearestReading(to: t - 15 * 60, tolerance: cgmTolerance),
                      let bg30 = nearestReading(to: t - 30 * 60, tolerance: cgmTolerance)
                else { result.skippedGap += 1
                    continue }

                let detIndex = Self.bisectRight(detTimes, t) - 1
                guard detIndex >= 0, t - dets[detIndex].ts <= determinationMaxAge
                else { result.skippedNoDetermination += 1
                    continue }
                let det = dets[detIndex]

                var targets: [Int: Double] = [:]
                for horizon in [30, 60] {
                    let targetTs = t + Double(horizon) * 60
                    guard targetTs <= nowTs,
                          let actual = nearestReading(to: targetTs, tolerance: targetTolerance)
                    else { continue }
                    targets[horizon] = actual
                }
                guard !targets.isEmpty else { result.skippedNoTarget += 1
                    continue }

                let carbIndex = Self.bisectLeft(carbTimes, t)
                let recentCarbs = carbs[max(0, carbIndex - carbEntryLookback) ..< carbIndex]
                let carbs1h = recentCarbs.filter { t - $0.ts <= 3600 }.reduce(0.0) { $0 + $1.grams }
                let carbs3h = recentCarbs.filter { t - $0.ts <= 3 * 3600 }.reduce(0.0) { $0 + $1.grams }

                let components = calendar.dateComponents([.hour, .minute], from: reading.date)
                let hour = Double(components.hour ?? 0) + Double(components.minute ?? 0) / 60.0

                samples.append(MLTrainer.Sample(
                    date: reading.date,
                    features: [
                        bg,
                        bg - bg5,
                        bg - bg15,
                        bg - bg30,
                        det.iob,
                        det.cob,
                        det.sens,
                        rate(at: t),
                        deliveredUnits(from: t - 3600, to: t),
                        carbs1h,
                        carbs3h,
                        sin(2 * Double.pi * hour / 24),
                        cos(2 * Double.pi * hour / 24)
                    ],
                    targets: targets
                ))
            }

            return Result(
                samples: samples,
                skippedGap: result.skippedGap,
                skippedNoDetermination: result.skippedNoDetermination,
                skippedNoTarget: result.skippedNoTarget,
                invalidReadingsDropped: result.invalidReadingsDropped
            )
        }
    }

    // MARK: - Binary search helpers

    static func bisectLeft(_ array: [Double], _ value: Double) -> Int {
        var low = 0, high = array.count
        while low < high {
            let mid = (low + high) / 2
            if array[mid] < value { low = mid + 1 } else { high = mid }
        }
        return low
    }

    static func bisectRight(_ array: [Double], _ value: Double) -> Int {
        var low = 0, high = array.count
        while low < high {
            let mid = (low + high) / 2
            if array[mid] <= value { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
