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
    /// Watches whether that activity is still on the Lock Screen at all.
    private var stateTask: Task<Void, Never>?
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
        case "isRunning":
            result(isRunning())
        case "start":
            perform(call, result: result) { try await self.start(arguments: $0) }
        case "update":
            perform(call, result: result) { try await self.update(arguments: $0) }
        case "restart":
            perform(call, result: result) { try await self.restart(arguments: $0) }
        case "pushToken":
            result(pushToken)
        case "end":
            // Awaited rather than fire-and-forget: an activity is usually ended
            // in order to start another one, and a `request` that lands while
            // the old activity is still up quietly updates it instead — leaving
            // the caller with the dead push token it was trying to replace.
            Task {
                await self.endAll()
                self.reply(result, true)
            }
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private func perform(
        _ call: FlutterMethodCall,
        result: @escaping FlutterResult,
        _ body: @escaping ([String: Any]) async throws -> Void
    ) {
        guard let arguments = call.arguments as? [String: Any] else {
            result(FlutterError(code: "bad_arguments", message: "Expected a map", details: nil))
            return
        }
        Task {
            do {
                try await body(arguments)
                self.reply(result, true)
            } catch {
                self.reply(result, FlutterError(code: "live_activity_failed", message: "\(error)", details: nil))
            }
        }
    }

    /// Answers a method call on the platform thread, which is the only thread
    /// a `FlutterResult` may be called on.
    private func reply(_ result: @escaping FlutterResult, _ value: Any?) {
        DispatchQueue.main.async { result(value) }
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

    /// Whether an activity is on the Lock Screen right now.
    ///
    /// Asked rather than remembered: the system ends activities on its own
    /// after a few hours, and the user can swipe one away at any moment — both
    /// of which usually happen while the app is not running to be told about
    /// it, so what the app last knew is worth nothing after a resume.
    private func isRunning() -> Bool {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                return Activity<FollowerActivityAttributes>.activities.contains { activity in
                    switch activity.activityState {
                    case .ended,
                         .dismissed:
                        return false
                    default:
                        // `.active`, and `.stale` — which is still on screen,
                        // just showing content the system knows is old.
                        return true
                    }
                }
            }
        #endif
        return false
    }

    // MARK: - ActivityKit

    private func start(arguments: [String: Any]) async throws {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                let state = try Self.contentState(from: arguments)

                // Only ever one activity: replace rather than stack.
                if let existing = Activity<FollowerActivityAttributes>.activities.first {
                    await existing.update(Self.content(state))
                    observe(existing)
                    return
                }

                try request(hostName: Self.hostName(from: arguments), state: state)
                return
            }
        #endif
        throw LiveActivityError.unsupported
    }

    /// Ends whatever is running and starts a fresh activity in its place.
    ///
    /// The way back after the user swiped the activity away, and the only
    /// correct way to restart one: the system hands out a push token when an
    /// activity is *requested*, so one that is merely updated can never gain
    /// its own — the host would go on pushing at an address that no longer
    /// draws anything.
    private func restart(arguments: [String: Any]) async throws {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                let state = try Self.contentState(from: arguments)
                await endAll()
                try request(hostName: Self.hostName(from: arguments), state: state)
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
        @available(iOS 16.2, *)
        private func request(hostName: String, state: FollowerActivityAttributes.ContentState) throws {
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
        }

        /// Follows the activity's push token, and its life, for as long as it
        /// has one.
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

            stateTask?.cancel()
            stateTask = Task { [weak self] in
                for await state in activity.activityStateUpdates {
                    switch state {
                    case .ended,
                         .dismissed:
                        DispatchQueue.main.async {
                            // Nothing else would tell the app the Lock Screen
                            // went away: the user swipes an activity off, or the
                            // system retires it, without the app being involved.
                            self?.publish(token: nil)
                            self?.channel.invokeMethod("onActivityEnded", arguments: nil)
                        }
                    default:
                        // `.stale` is not the end of anything — the activity is
                        // still there, showing content the system knows is old.
                        break
                    }
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

    private func update(arguments: [String: Any]) async throws {
        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                let state = try Self.contentState(from: arguments)
                let activities = Activity<FollowerActivityAttributes>.activities
                guard !activities.isEmpty else {
                    // Nothing running: treat an update as a start, so an activity
                    // the system ended after its 8-hour limit comes back on the
                    // next reading rather than staying gone until the app is opened.
                    try await start(arguments: arguments)
                    return
                }
                for activity in activities {
                    await activity.update(Self.content(state))
                }
                return
            }
        #endif
        throw LiveActivityError.unsupported
    }

    private func endAll() async {
        // Cancelled before the activity is ended, not after: a deliberate end
        // is not the user dismissing anything, and Dart must not be told it
        // lost an activity that is in the middle of being replaced.
        tokenTask?.cancel()
        tokenTask = nil
        stateTask?.cancel()
        stateTask = nil

        #if canImport(ActivityKit)
            if #available(iOS 16.2, *) {
                for activity in Activity<FollowerActivityAttributes>.activities {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        #endif
        // The token dies with the activity; tell Dart so the host is told to
        // stop pushing to it rather than pushing into the void.
        DispatchQueue.main.async { self.publish(token: nil) }
    }

    private static func hostName(from arguments: [String: Any]) -> String {
        arguments["hostName"] as? String ?? "Trio"
    }

    #if canImport(ActivityKit)
        @available(iOS 16.2, *)
        private static func content(
            _ state: FollowerActivityAttributes.ContentState
        ) -> ActivityContent<FollowerActivityAttributes.ContentState> {
            // The stale date is what makes the Lock Screen admit it has stopped
            // keeping up: the system re-renders the activity when it passes, and
            // the views draw the reading struck through from then on. Without it
            // an activity nobody updates keeps showing its last number as though
            // it had just arrived. Six minutes matches the widgets.
            ActivityContent(state: state, staleDate: state.staleDate)
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
