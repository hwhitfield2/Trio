import Flutter
import UIKit

#if canImport(ActivityKit)
    import ActivityKit
#endif

/// Bridges Dart to ActivityKit.
///
/// A plugin rather than a channel registered by hand from AppDelegate: Flutter's
/// generated registrant wires this up on whichever iOS template the SDK ships,
/// and — more importantly — against the same engine the background push handler
/// runs on, so a status push that arrives while the app is in the background can
/// still refresh the activity.
public class TrioLiveActivityPlugin: NSObject, FlutterPlugin {
    private let channel: FlutterMethodChannel
    /// Watches the running activity's push token. One activity at a time, so
    /// one task at a time.
    private var tokenTask: Task<Void, Never>?
    private var pushToken: String?

    init(channel: FlutterMethodChannel) {
        self.channel = channel
        super.init()
    }

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "trio_follower/live_activity",
            binaryMessenger: registrar.messenger()
        )
        let instance = TrioLiveActivityPlugin(channel: channel)
        registrar.addMethodCallDelegate(instance, channel: channel)
        // An activity survives the app being killed, so on launch there may
        // already be one running whose token needs watching again.
        instance.observeRunningActivity()
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "isSupported":
            result(supportInfo())
        case "start":
            perform(call, result: result) { try self.start(arguments: $0) }
        case "update":
            perform(call, result: result) { try self.update(arguments: $0) }
        case "pushToken":
            result(pushToken)
        case "end":
            Task { await self.endAll() }
            result(true)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func perform(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult,
        _ body: @escaping ([String: Any]) throws -> Void
    ) {
        guard let arguments = call.arguments as? [String: Any] else {
            result(FlutterError(code: "bad_arguments", message: "Expected a map", details: nil))
            return
        }
        do {
            try body(arguments)
            result(true)
        } catch {
            result(FlutterError(code: "live_activity_failed", message: "\(error)", details: nil))
        }
    }

    /// Two separate answers: whether the OS can do Live Activities at all, and
    /// whether the user has left them switched on for this app. Collapsing them
    /// would hide the setting exactly when someone needs to be told to turn it
    /// back on.
    private func supportInfo() -> [String: Bool] {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                return [
                    "available": true,
                    "enabled": ActivityAuthorizationInfo().areActivitiesEnabled
                ]
            }
        #endif
        return ["available": false, "enabled": false]
    }

    // MARK: - ActivityKit

    private func start(arguments: [String: Any]) throws {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                let hostName = arguments["hostName"] as? String ?? "Trio"
                let state = try Self.contentState(from: arguments)

                // Only ever one activity: replace rather than stack.
                if let existing = Activity<FollowerActivityAttributes>.activities.first {
                    Task {
                        await existing.update(Self.content(state))
                    }
                    observe(existing)
                    return
                }

                // `.token` asks the system for an APNS token addressed straight
                // at this activity. The host can then update the Lock Screen
                // without the app being woken at all, which is the only way the
                // activity stays current while the app is suspended. The token
                // is only ever sent to the host when the user opts in; minting
                // one costs nothing on its own.
                let activity = try Activity.request(
                    attributes: FollowerActivityAttributes(hostName: hostName),
                    content: Self.content(state),
                    pushType: .token
                )
                observe(activity)
                return
            }
        #endif
        throw LiveActivityError.unsupported
    }

    private func observeRunningActivity() {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                guard let existing = Activity<FollowerActivityAttributes>.activities.first else { return }
                observe(existing)
            }
        #endif
    }

    #if canImport(ActivityKit)
        /// Follows the activity's push token for as long as it lives.
        ///
        /// The token is not available synchronously after `request`, and the
        /// system rotates it during the activity's life, so the stream is the
        /// only reliable source — reading `activity.pushToken` once would leave
        /// the host pushing at a dead address.
        @available(iOS 16.2, *)
        private func observe(_ activity: Activity<FollowerActivityAttributes>) {
            tokenTask?.cancel()
            tokenTask = Task { [weak self] in
                for await tokenData in activity.pushTokenUpdates {
                    let token = tokenData.map { String(format: "%02x", $0) }.joined()
                    DispatchQueue.main.async { self?.publish(token: token) }
                }
            }
        }
    #endif

    /// Hands the token to Dart, which decides whether the host may have it.
    private func publish(token: String?) {
        pushToken = token
        // A different name from the "pushToken" method Dart calls into, so
        // the two directions of this channel stay easy to tell apart.
        channel.invokeMethod("onPushToken", arguments: token)
    }

    private func update(arguments: [String: Any]) throws {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                let state = try Self.contentState(from: arguments)
                let activities = Activity<FollowerActivityAttributes>.activities
                guard !activities.isEmpty else {
                    // Nothing running: treat an update as a start, so an activity
                    // the system ended after its 8-hour limit comes back on the
                    // next reading rather than staying gone until the app is opened.
                    try start(arguments: arguments)
                    return
                }
                Task {
                    for activity in activities {
                        await activity.update(Self.content(state))
                    }
                }
                return
            }
        #endif
        throw LiveActivityError.unsupported
    }

    private func endAll() async {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                for activity in Activity<FollowerActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        #endif
        tokenTask?.cancel()
        tokenTask = nil
        // The token dies with the activity; tell Dart so the host is told to
        // stop pushing to it rather than pushing into the void.
        DispatchQueue.main.async { self.publish(token: nil) }
    }

    #if canImport(ActivityKit)
        @available(iOS 16.2, *)
        private static func content(
            _ state: FollowerActivityAttributes.ContentState
        ) -> ActivityContent<FollowerActivityAttributes.ContentState> {
            // The system dims the activity once it is stale. Six minutes matches
            // when the widgets strike the reading through.
            ActivityContent(state: state, staleDate: state.reading.addingTimeInterval(6 * 60))
        }

        @available(iOS 16.2, *)
        private static func contentState(
            from arguments: [String: Any]
        ) throws -> FollowerActivityAttributes.ContentState {
            guard let payload = arguments["state"] as? String,
                  let data = payload.data(using: .utf8)
            else { throw LiveActivityError.badPayload }

            return try JSONDecoder().decode(FollowerActivityAttributes.ContentState.self, from: data)
        }
    #endif

    private enum LiveActivityError: Error {
        case unsupported
        case badPayload
    }
}
