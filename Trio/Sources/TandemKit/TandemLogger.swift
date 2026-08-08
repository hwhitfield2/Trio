import Foundation

/// Thin wrapper over Trio's global logger so TandemKit code reads like a
/// standalone pump kit and can be extracted into one later.
struct TandemLogger {
    let category: String

    func info(_ message: String) {
        debug(.deviceManager, "[Tandem \(category)] \(message)")
    }

    func error(_ message: String) {
        warning(.deviceManager, "[Tandem \(category)] \(message)")
    }
}
