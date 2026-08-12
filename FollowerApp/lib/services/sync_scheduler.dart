import 'dart:math';

/// Decides when the follower should ask the host for a status snapshot on its
/// own, instead of waiting for one to be pushed.
///
/// Status normally arrives unprompted: the host pushes a snapshot on every
/// glucose and loop update. Those are silent background pushes, and both iOS
/// and Android are free to delay, coalesce or drop them — the system treats
/// them as a budgeted hint, not a delivery guarantee. That is why the numbers
/// on screen can sit still until the user pulls to refresh.
///
/// This scheduler is the safety net behind those pushes: while the app is on
/// screen it notices that nothing has arrived for longer than a CGM cycle and
/// asks the host directly, which is exactly what pull-to-refresh does.
///
/// Every request costs the host a push, so the policy is deliberately quiet:
/// it fires only when the data is actually stale, never more often than
/// [minimumInterval], and backs off towards [maximumBackoff] while the host
/// stays silent — an unreachable host is not worth asking every few minutes.
class SyncScheduler {
  SyncScheduler({
    this.staleAfter = const Duration(minutes: 6),
    this.minimumInterval = const Duration(minutes: 5),
    this.maximumBackoff = const Duration(minutes: 30),
  });

  /// How old the newest snapshot may get before the app asks by itself. One
  /// CGM cycle plus a minute of grace, so a push that is merely a little late
  /// still wins the race against the request it would otherwise trigger.
  final Duration staleAfter;

  /// Shortest gap between two automatic requests.
  final Duration minimumInterval;

  /// Longest gap the backoff can grow to.
  final Duration maximumBackoff;

  DateTime? _lastRequestAt;
  int _consecutiveFailures = 0;

  /// Gap required before the next automatic request: [minimumInterval],
  /// doubled per unanswered request and capped at [maximumBackoff].
  Duration get retryInterval {
    final scaled = minimumInterval * (1 << min(_consecutiveFailures, 8));
    return scaled > maximumBackoff ? maximumBackoff : scaled;
  }

  /// Whether the app should ask the host for a snapshot now. [snapshotAt] is
  /// the timestamp of the newest snapshot received, or null when there is
  /// none yet.
  bool shouldRequest({required DateTime now, DateTime? snapshotAt}) {
    final lastRequestAt = _lastRequestAt;
    if (lastRequestAt != null && now.difference(lastRequestAt) < retryInterval) {
      return false;
    }
    // Nothing at all to show: any moment is a good moment to ask.
    if (snapshotAt == null) return true;
    return now.difference(snapshotAt) >= staleAfter;
  }

  /// Records that a request was just sent, whatever its outcome — the host is
  /// asked no more than once per [retryInterval] even if it never answers.
  void recordRequest(DateTime now) => _lastRequestAt = now;

  /// A snapshot arrived: back to the shortest interval.
  void recordSuccess() => _consecutiveFailures = 0;

  /// The host did not answer; widen the gap before the next attempt.
  void recordFailure() {
    if (_consecutiveFailures < 8) _consecutiveFailures++;
  }

  /// Forgets the history, e.g. after pairing with a different host.
  void reset() {
    _lastRequestAt = null;
    _consecutiveFailures = 0;
  }
}
