import Foundation

/// Observation hook for in-process listeners (the settings view, mostly).
/// CGMManagerStatusObserver is too narrow — it only fires on cgmManagerStatus
/// changes, not arbitrary state updates or new readings.
public protocol LibreLoopStateObserver: AnyObject {
    func libreLoopCGMManager(_ manager: LibreLoopCGMManager,
                             didUpdate state: LibreLoopCGMManagerState,
                             latestSample: LibreLoopGlucoseSample?)
}

extension LibreLoopCGMManager {
    public func addStateObserver(_ observer: LibreLoopStateObserver) {
        stateObservers.add(observer)
    }

    public func removeStateObserver(_ observer: LibreLoopStateObserver) {
        stateObservers.remove(observer)
    }

    func notifyStateObservers() {
        stateObservers.notify { [weak self] observer in
            guard let self else { return }
            observer.libreLoopCGMManager(self,
                                          didUpdate: self.state,
                                          latestSample: self.latestSample)
        }
    }
}

/// Tiny weak-observer set scoped to LibreLoop. WeakSynchronizedSet in LoopKit
/// expects CGMManagerStatusObserver (its generic parameter is constrained); we
/// roll our own to stay AnyObject-generic.
final class LibreLoopWeakObserverSet<Observer> {
    private let lock = NSLock()
    private var observers: [WeakBox] = []

    private struct WeakBox {
        weak var ref: AnyObject?
    }

    func add(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        observers.append(WeakBox(ref: ref))
        lock.unlock()
    }

    func remove(_ observer: Observer) {
        let ref = observer as AnyObject
        lock.lock()
        observers.removeAll { $0.ref === ref || $0.ref == nil }
        lock.unlock()
    }

    func notify(_ body: @escaping (Observer) -> Void) {
        lock.lock()
        let snapshot = observers.compactMap { $0.ref as? Observer }
        observers.removeAll { $0.ref == nil }
        lock.unlock()
        DispatchQueue.main.async {
            for obs in snapshot { body(obs) }
        }
    }
}
