import Foundation

enum SleepSafetySettings {
    enum Config {}
}

protocol SleepSafetySettingsProvider {}

/// An override preset shown in the sleep-window picker.
struct SleepOverridePresetOption: Identifiable, Equatable {
    let id: String
    let name: String
}
