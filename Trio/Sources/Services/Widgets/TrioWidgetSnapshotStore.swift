import Foundation
import WidgetKit

/// The widget kinds Trio publishes, used to reload a single widget's timelines.
enum TrioWidgetKind {
    static let glucose = "TrioGlucoseWidget"
}

/// Carries `TrioWidgetSnapshot` from the Trio app to the widget extension.
///
/// The extension cannot reach Trio's Core Data store, so the app publishes a snapshot into the
/// shared app group every time the Live Activity content changes, and the widgets read it back.
struct TrioWidgetSnapshotStore {
    static let shared = TrioWidgetSnapshotStore()

    private static let snapshotKey = "trioWidgetSnapshot"

    /// Defaults for the app group both targets belong to. The suite name is read from the Info.plist
    /// key that both the app and the widget extension populate from the `APP_GROUP_ID` build setting.
    private var sharedDefaults: UserDefaults? {
        guard let suiteName = Bundle.main.object(forInfoDictionaryKey: "AppGroupID") as? String,
              !suiteName.isEmpty
        else { return nil }

        return UserDefaults(suiteName: suiteName)
    }

    /// Publishes a snapshot and asks WidgetKit to re-render the widgets that display it.
    ///
    /// The app rebuilds the live activity content on every data change, which happens several times
    /// per glucose reading. WidgetKit budgets how often it will reload a widget, so a snapshot that
    /// shows the same numbers as the last one published is dropped rather than spending a reload.
    func save(_ snapshot: TrioWidgetSnapshot) {
        guard let sharedDefaults, snapshot != load(), let data = try? JSONEncoder().encode(snapshot) else { return }

        sharedDefaults.set(data, forKey: Self.snapshotKey)
        WidgetCenter.shared.reloadTimelines(ofKind: TrioWidgetKind.glucose)
    }

    /// Reads the most recently published snapshot, or `nil` if the app has not published one yet.
    func load() -> TrioWidgetSnapshot? {
        guard let data = sharedDefaults?.data(forKey: Self.snapshotKey) else { return nil }

        return try? JSONDecoder().decode(TrioWidgetSnapshot.self, from: data)
    }
}
