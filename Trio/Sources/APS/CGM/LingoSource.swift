import Algorithms
import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI

/// Glucose source for the Abbott FreeStyle Lingo biosensor.
///
/// The Lingo is FreeStyle Libre 3 family hardware (same sensor platform, different product code),
/// but its Bluetooth stream is encrypted and can only be decrypted by Abbott's own Lingo app.
/// The Lingo app syncs its readings to Apple Health, so Trio reads them from HealthKit here.
///
/// Abbott writes the samples to Apple Health with a delay (about 3 hours) and only within the
/// Lingo reporting range (roughly 55–200 mg/dL). Readings arrive with their original timestamps
/// and are stored for history, statistics and uploads. This source is display-only by design:
/// APSManager refuses to determine a dosing recommendation while this CGM type is selected,
/// on top of the general 12-minute glucose staleness gate.
///
/// Samples are only ingested from ONE user-selected Health source app (normally the Lingo app),
/// chosen in the CGM settings sheet. Without a selection nothing is ingested.
final class LingoSource: GlucoseSource {
    struct HealthSourceInfo: Identifiable, Equatable {
        let name: String
        let bundleIdentifier: String
        var id: String { bundleIdentifier }
    }

    var glucoseManager: FetchGlucoseManager?
    var cgmManager: CGMManagerUI?

    private let processQueue = DispatchQueue(label: "LingoSource.processQueue")
    private let healthKitStore = HKHealthStore()
    private let glucoseType = HKObjectType.quantityType(forIdentifier: .bloodGlucose)!

    /// How far back each query looks for samples. Re-reading the same samples is harmless:
    /// GlucoseStorage deduplicates both new and backfilled entries against Core Data.
    private static let fetchWindow: TimeInterval = 24 * 60 * 60

    /// The Lingo app pushes batches to Apple Health infrequently; polling faster than this is
    /// wasted work. New samples still arrive immediately through the HKObserverQuery push path.
    private static let pollInterval: TimeInterval = 4.5 * 60

    private static let selectedSourceKey = "LingoSource.selectedSourceBundleIdentifier"

    // Mutable state below is confined to processQueue.
    private var observerQuery: HKObserverQuery?
    private var didRequestPermission = false
    private var didAttemptAutoSelect = false
    private var lastPollDate = Date.distantPast

    /// Bundle identifier of the Health source app whose samples are ingested.
    /// nil means nothing is ingested until an app is selected in the settings sheet.
    var selectedSourceBundleIdentifier: String? {
        get { UserDefaults.standard.string(forKey: Self.selectedSourceKey) }
        set {
            if let newValue = newValue {
                UserDefaults.standard.set(newValue, forKey: Self.selectedSourceKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.selectedSourceKey)
            }
        }
    }

    deinit {
        if let observerQuery = observerQuery {
            healthKitStore.stop(observerQuery)
        }
    }

    /// True while this source is the one FetchGlucoseManager currently polls.
    /// The lazily created instance outlives CGM deletion, so background pushes check this first.
    private var isActiveSource: Bool {
        glucoseManager?.cgmGlucoseSourceType == .lingo
    }

    func stopObserving() {
        processQueue.async {
            if let observerQuery = self.observerQuery {
                self.healthKitStore.stop(observerQuery)
                self.observerQuery = nil
            }
            self.healthKitStore.disableBackgroundDelivery(for: self.glucoseType) { _, _ in }
        }
    }

    /// Ask the user for read access to blood glucose. The system sheet is only shown while
    /// authorization is undetermined; afterwards HealthKit intentionally hides the outcome
    /// from apps, so callers cannot inspect whether access was granted.
    func requestReadPermission(completion: ((Bool) -> Void)? = nil) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion?(false)
            return
        }
        healthKitStore.requestAuthorization(toShare: nil, read: [glucoseType]) { success, error in
            if let error = error {
                warning(.deviceManager, "LINGO - HealthKit authorization request failed", error: error)
            }
            DispatchQueue.main.async {
                completion?(success)
            }
        }
    }

    /// Reports whether the system permission sheet can still be shown, so the settings UI can
    /// fall back to Health-app guidance once the user has already made a choice.
    func canPromptForPermission(_ completion: @escaping (Bool) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion(false)
            return
        }
        healthKitStore.getRequestStatusForAuthorization(toShare: [], read: [glucoseType]) { status, _ in
            DispatchQueue.main.async {
                completion(status == .shouldRequest)
            }
        }
    }

    /// Apps (other than Trio) that have written blood glucose to Apple Health.
    /// Completion is called on the main queue.
    func fetchAvailableSources(_ completion: @escaping ([HealthSourceInfo]) -> Void) {
        guard HKHealthStore.isHealthDataAvailable() else {
            completion([])
            return
        }
        let query = HKSourceQuery(sampleType: glucoseType, samplePredicate: nil) { _, sources, error in
            if let error = error {
                warning(.deviceManager, "LINGO - HealthKit source query failed", error: error)
            }
            let ownBundleIdentifier = Bundle.main.bundleIdentifier
            let infos = (sources ?? [])
                .filter { $0.bundleIdentifier != ownBundleIdentifier }
                .map { HealthSourceInfo(name: $0.name, bundleIdentifier: $0.bundleIdentifier) }
                .sorted { $0.name.lowercased() < $1.name.lowercased() }
            DispatchQueue.main.async { completion(infos) }
        }
        healthKitStore.execute(query)
    }

    func fetch(_: DispatchTimer?) -> AnyPublisher<[BloodGlucose], Never> {
        guard HKHealthStore.isHealthDataAvailable() else {
            return Just([]).eraseToAnyPublisher()
        }

        return Future<[BloodGlucose], Error> { [weak self] promise in
            guard let self = self else {
                promise(.success([]))
                return
            }
            self.processQueue.async {
                // Once per launch: shows the system sheet only while authorization is
                // undetermined, i.e. right after the user adds this CGM.
                if !self.didRequestPermission {
                    self.didRequestPermission = true
                    self.requestReadPermission()
                }

                self.startObservingIfNeeded()

                guard Date().timeIntervalSince(self.lastPollDate) >= Self.pollInterval else {
                    promise(.success([]))
                    return
                }
                self.lastPollDate = Date()

                self.withSelectedSource { selectedSource in
                    guard let selectedSource = selectedSource else {
                        promise(.success([]))
                        return
                    }
                    self.queryGlucoseSamples(from: selectedSource) { promise(.success($0)) }
                }
            }
        }
        .timeout(60, scheduler: processQueue, options: nil, customError: nil)
        .replaceError(with: [])
        .eraseToAnyPublisher()
    }

    func fetchIfNeeded() -> AnyPublisher<[BloodGlucose], Never> {
        fetch(nil)
    }

    /// Resolve the source app to ingest from, auto-selecting once per launch when the choice
    /// is unambiguous: a candidate recognizably named Lingo, or the only candidate there is.
    /// Must be called on processQueue; the completion is called on processQueue as well.
    private func withSelectedSource(_ completion: @escaping (String?) -> Void) {
        if let selected = selectedSourceBundleIdentifier {
            completion(selected)
            return
        }
        guard !didAttemptAutoSelect else {
            completion(nil)
            return
        }
        didAttemptAutoSelect = true
        fetchAvailableSources { candidates in
            self.processQueue.async {
                if self.selectedSourceBundleIdentifier == nil {
                    if let lingoApp = candidates.first(where: {
                        $0.name.lowercased().contains("lingo") || $0.bundleIdentifier.lowercased().contains("lingo")
                    }) {
                        self.selectedSourceBundleIdentifier = lingoApp.bundleIdentifier
                    } else if candidates.count == 1, let only = candidates.first {
                        self.selectedSourceBundleIdentifier = only.bundleIdentifier
                    }
                }
                completion(self.selectedSourceBundleIdentifier)
            }
        }
    }

    /// Register a long-lived observer so new Lingo samples are picked up as soon as the Lingo app
    /// writes them, including in background (Trio has the HealthKit background-delivery entitlement).
    /// Must be called on processQueue.
    private func startObservingIfNeeded() {
        guard observerQuery == nil else { return }

        let query = HKObserverQuery(sampleType: glucoseType, predicate: nil) { [weak self] _, completionHandler, error in
            guard let self = self, error == nil else {
                completionHandler()
                return
            }
            guard self.isActiveSource else {
                // The user deleted this CGM or switched sources: shut the observer down.
                self.stopObserving()
                completionHandler()
                return
            }
            self.processQueue.async {
                self.withSelectedSource { selectedSource in
                    guard let selectedSource = selectedSource else {
                        completionHandler()
                        return
                    }
                    self.queryGlucoseSamples(from: selectedSource) { newGlucose in
                        if newGlucose.isNotEmpty, self.isActiveSource {
                            self.glucoseManager?.newGlucoseFromCgmManager(newGlucose: newGlucose)
                        }
                        // Called only after the sample query finished, so background delivery
                        // keeps the app alive long enough to hand the readings over.
                        completionHandler()
                    }
                }
            }
        }
        observerQuery = query
        healthKitStore.execute(query)

        healthKitStore.enableBackgroundDelivery(for: glucoseType, frequency: .immediate) { success, error in
            if let error = error {
                warning(.deviceManager, "LINGO - Failed to enable HealthKit background delivery", error: error)
            } else if success {
                debug(.deviceManager, "LINGO - HealthKit background delivery enabled")
            }
        }
    }

    private func queryGlucoseSamples(from sourceBundleIdentifier: String, completion: @escaping ([BloodGlucose]) -> Void) {
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-Self.fetchWindow),
            end: nil,
            options: .strictStartDate
        )
        let sortByDate = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        let query = HKSampleQuery(
            sampleType: glucoseType,
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sortByDate]
        ) { [weak self] _, samples, error in
            guard let self = self else {
                completion([])
                return
            }
            if let error = error {
                // Only undetermined authorization produces an error here. A denied read
                // returns an empty result set instead: HealthKit hides read denial from apps.
                warning(.deviceManager, "LINGO - HealthKit glucose query failed", error: error)
                completion([])
                return
            }
            completion(self.mapSamples(samples, from: sourceBundleIdentifier))
        }
        healthKitStore.execute(query)
    }

    private func mapSamples(_ samples: [HKSample]?, from sourceBundleIdentifier: String) -> [BloodGlucose] {
        let usable = (samples as? [HKQuantitySample] ?? []).filter { sample in
            // Allowlist: only the user-selected source app (normally the Lingo app) is ingested.
            // Glucose that other apps write to Health with current timestamps must never reach
            // the loop through this source; this also excludes Trio's own Health uploads.
            guard sample.sourceRevision.source.bundleIdentifier == sourceBundleIdentifier else { return false }
            // Skip manual (finger-stick style) entries typed into the source app.
            guard (sample.metadata?[HKMetadataKeyWasUserEntered] as? Bool) != true else { return false }
            let value = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
            return (39 ... 500).contains(value)
        }

        // Lingo samples come in 5-minute steps; don't fabricate a trend across larger gaps,
        // e.g. around stretches Abbott clipped for being outside the Lingo reporting range.
        let directions: [BloodGlucose.Direction?] = [nil]
            + usable.windows(ofCount: 2).map { window -> BloodGlucose.Direction? in
                let pair = Array(window)
                guard pair.count == 2 else { return nil }
                guard pair[1].startDate.timeIntervalSince(pair[0].startDate) <= 7.5 * 60 else { return nil }
                let firstValue = Int(pair[0].quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
                let secondValue = Int(pair[1].quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
                return .init(trend: secondValue - firstValue)
            }

        return usable.enumerated().map { index, sample -> BloodGlucose in
            let value = Int(sample.quantity.doubleValue(for: .milligramsPerDeciliter).rounded())
            return BloodGlucose(
                id: sample.uuid.uuidString,
                sgv: value,
                direction: directions[index],
                date: Decimal(Int(sample.startDate.timeIntervalSince1970 * 1000)),
                dateString: sample.startDate,
                unfiltered: Decimal(value),
                filtered: nil,
                noise: nil,
                glucose: value,
                type: "sgv"
            )
        }
    }

    func sourceInfo() -> [String: Any]? {
        [GlucoseSourceKey.description.rawValue: "FreeStyle Lingo (Apple Health)"]
    }
}
