import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/command.dart';
import '../models/display_preferences.dart';
import '../models/glucose_ranges.dart';
import '../models/pairing_bundle.dart';
import '../models/status_snapshot.dart';
import '../services/command_service.dart';
import '../services/display_preferences_store.dart';
import '../services/host_migration_service.dart';
import '../services/pairing_store.dart';
import '../services/push_service.dart';
import '../services/reading_history_store.dart';
import '../services/status_service.dart';
import '../services/live_activity_bridge.dart';
import '../services/sync_scheduler.dart';
import '../services/widget_bridge.dart';

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  AppState({PairingStore? store, PushService? push, SyncScheduler? scheduler})
      : _store = store ?? PairingStore(),
        _push = push ?? PushService.instance,
        _scheduler = scheduler ?? SyncScheduler();

  final PairingStore _store;
  final PushService _push;
  final SyncScheduler _scheduler;

  PairingBundle? bundle;
  CommandService? _commandService;
  StatusService? _statusService;
  HostMigrationService? _hostMigrationService;

  bool initialized = false;

  /// Latest status received from the host device (the only data source).
  StatusSnapshot? snapshot;

  /// Everything the host has pushed, folded into one rolling 48-hour window.
  /// What the chart draws from: a single snapshot only carries a few hours,
  /// and the longer chart durations show what this device has collected.
  ReadingHistory readingHistory = ReadingHistory.empty;

  /// Whether this device can run Live Activities, and whether the user has left
  /// them switched on for the app in iOS Settings.
  LiveActivitySupport liveActivitySupport = LiveActivitySupport.unsupported;
  bool liveActivityEnabled = false;

  /// Whether an activity is actually on the Lock Screen right now.
  ///
  /// Separate from [liveActivityEnabled], which is only what the user asked
  /// for: the system retires activities after a few hours, and they can be
  /// swiped away at any time, so "switched on" and "on screen" routinely
  /// disagree — and the difference is the whole reason there is a way to
  /// start a new one by hand.
  bool liveActivityRunning = false;

  /// Whether the host may update the Live Activity directly over APNS. Off
  /// unless the user turns it on: it is the one path where the push service
  /// carries readable data rather than ciphertext.
  bool liveActivityRemoteUpdates = false;

  /// How the Live Activity and the widgets lay themselves out. The widget
  /// extension reads these from the shared app group; this copy drives the
  /// settings screen.
  DisplayPreferences displayPreferences = const DisplayPreferences();

  /// Version the host says is available, when it has nudged this device about
  /// one. Informational only: unlike commands and status, a nudge rides in the
  /// clear alongside a notification, so it is never acted on automatically —
  /// it only puts a line on screen for the user to act on themselves.
  String? updateAvailableVersion;

  /// When this device last asked the host to stop insulin. Kept so the screen
  /// can say "asked, not yet confirmed" — which is a different and more
  /// dangerous state than "insulin is stopped", and must never be shown as if
  /// it were the latter.
  DateTime? suspendRequestedAt;

  /// Why the host refused or could not carry out the last command, when it
  /// told us. An accepted push says only that Apple took the message, so
  /// without this a rejected command looks identical to one still in flight.
  String? commandError;
  String? statusHint;
  List<CommandRecord> history = [];

  /// A number to reach whoever is holding the host phone, as the follower
  /// entered it.
  ///
  /// Kept here rather than taken from the pairing bundle because the host does
  /// not know it: pairing carries push addresses and secrets, not a phone
  /// number. It exists for exactly one moment — insulin is stopped and nobody
  /// there has answered the alarm — when the useful thing this app can offer
  /// is not another screen but a way to call.
  String? hostContact;

  static const _historyKey = 'trio_follower.history';
  static const _hostContactKey = 'trio_follower.host_contact';

  /// How often the app re-checks, while it is on screen, whether the status is
  /// still fresh. Also the cadence at which the "from host x min ago" label is
  /// redrawn, since that text ages on its own.
  static const _tickInterval = Duration(seconds: 30);

  Timer? _ticker;
  bool _observingLifecycle = false;
  bool _statusRequestInFlight = false;

  /// When a history backfill was last asked for, and how many slices of the
  /// answer are still outstanding.
  ///
  /// The request is throttled because a follower flicking between 12, 24 and
  /// 48 hours would otherwise ask the host for the same readings three times
  /// in as many seconds, and every answer is a push someone else's phone has
  /// to send.
  DateTime? _historyRequestedAt;
  int _historySlicesOutstanding = 0;

  static const _historyThrottle = Duration(minutes: 5);

  /// Whether a backfill is in flight, for the line under the chart's span
  /// picker. A span the device cannot fill yet should say so rather than draw
  /// an empty chart and let the user conclude the app is broken.
  bool get backfilling => _historySlicesOutstanding > 0;

  /// Last Live Activity token the host acknowledged, so a token that has not
  /// changed is not re-sent on every activity update.
  String? _registeredLiveActivityToken;

  /// Set when the activity ended while the app was there to see it, which in
  /// practice means the user swiped it off the Lock Screen. It then stays off
  /// until they ask for it back: an activity that reappears every time the app
  /// is opened is not a feature, it is an argument. An activity the *system*
  /// retired, or one lost while the app was not running, carries no such flag
  /// and comes back on its own.
  bool _liveActivityDismissedByUser = false;

  bool get isPaired => bundle != null;

  /// Live limits: prefer the host's latest snapshot over the pairing-time
  /// values.
  double get maxBolus => snapshot?.maxBolus ?? bundle?.limits.maxBolus ?? 10;
  double get maxCarbs => snapshot?.maxCarbs ?? bundle?.limits.maxCarbs ?? 250;
  String get units => snapshot?.units ?? bundle?.limits.units ?? 'mg/dL';

  /// The host's AI food search configuration, or null when the host has the
  /// feature off. Read from the securely stored bundle, which every incoming
  /// snapshot keeps current (see [_syncAiConfig]) — snapshots persisted to
  /// plain storage have the credentials stripped, so they are not the source.
  AiConfig? get aiConfig => bundle?.ai;

  /// The user asked for a Lock Screen and there is not one — dismissed, or
  /// retired by the system after a few hours.
  ///
  /// Its own getter because the home screen has to know whether the notice
  /// will draw anything *before* it lays the panels out: a panel that decides
  /// for itself to render nothing still takes its gap of ground with it.
  bool get liveActivityMissing =>
      liveActivitySupport.available &&
      liveActivityEnabled &&
      !liveActivityRunning &&
      snapshot?.latest != null;

  /// Insulin on board as the screens write it, or null when the host has not
  /// reported any. The command screens carry it in their title bar: a bolus
  /// decided without knowing what is already working is a guess.
  String? get iobLabel {
    final iob = snapshot?.iob;
    return iob == null ? null : '${iob.toStringAsFixed(2)} U';
  }

  /// Carbs on board, the same way.
  String? get cobLabel {
    final cob = snapshot?.cob;
    return cob == null ? null : '${cob.toStringAsFixed(0)} g';
  }

  /// What glucose is coloured by everywhere this app draws it: the host's
  /// ranges, with whatever this device chose to see instead.
  GlucoseRanges get glucoseRanges =>
      displayPreferences.resolveRanges(snapshot?.glucoseRanges ?? GlucoseRanges.defaults);

  /// The window the home screen chart spans.
  Duration get chartDuration => Duration(hours: displayPreferences.chartHours);

  /// Picks a chart span, remembering it with the other display choices — and
  /// asks the host to fill it in when this device has not collected that far
  /// back itself.
  Future<void> setChartHours(int hours) async {
    await setDisplayPreferences(displayPreferences.copyWith(chartHours: hours));
    await requestHistoryIfNeeded();
  }

  /// Asks the host for the readings the chosen span needs and this device does
  /// not have.
  ///
  /// A status snapshot carries only the few hours that fit an APNS push, so
  /// the longer spans are otherwise limited to whatever this phone happened to
  /// be awake for — and a re-pair, which clears the history, empties them
  /// outright. No-op when the span is already covered.
  Future<void> requestHistoryIfNeeded({bool force = false}) async {
    if (!isPaired) return;
    final wanted = Duration(hours: displayPreferences.chartHours);
    // A little slack: readings are five minutes apart and the newest is
    // seconds old, so a window is never covered to the exact second.
    if (!force && readingHistory.coverage + const Duration(minutes: 10) >= wanted) return;

    final now = DateTime.now();
    final lastAsked = _historyRequestedAt;
    if (!force && lastAsked != null && now.difference(lastAsked) < _historyThrottle) return;
    _historyRequestedAt = now;

    final record = await sendCommand(
      TrioCommand.historyRequest(hours: displayPreferences.chartHours),
    );
    if (record == null) return;
    if (!record.accepted) {
      // Let the next span change try again rather than sitting out the
      // throttle on a request that never reached the host.
      _historyRequestedAt = null;
      statusHint = 'Could not ask the host for older readings: ${record.detail}';
      notifyListeners();
      return;
    }
    // The host answers with one push per slice; the count is only known when
    // the first arrives. One is enough to show the backfill as running.
    _historySlicesOutstanding = 1;
    notifyListeners();
  }

  Future<void> initialize() async {
    bundle = await _store.loadPairing();
    _rebuildServices();
    await _loadHistory();
    await _loadHostContact();
    snapshot = await _statusService?.loadPersisted();
    readingHistory = await ReadingHistoryStore.load();
    // Folding the persisted snapshot in covers the first launch after an
    // update from a build that kept no history: the chart starts with the
    // snapshot's few hours rather than nothing.
    if (snapshot != null) {
      readingHistory = readingHistory.merge(snapshot!);
    }
    liveActivitySupport = await LiveActivityBridge.support();
    liveActivityEnabled = await LiveActivityBridge.isEnabled();
    liveActivityRemoteUpdates = await LiveActivityBridge.remoteUpdatesEnabled();
    displayPreferences = await DisplayPreferencesStore.load();
    initialized = true;
    await WidgetBridge.publish(snapshot, preferences: displayPreferences);
    await _publishLiveActivity(snapshot);

    _push.onMessage(_handlePushData);
    _push.onNewToken((_) => registerPush(force: true));
    LiveActivityBridge.onPushToken(_handleLiveActivityToken);
    LiveActivityBridge.onActivityEnded(_handleLiveActivityEnded);

    if (!_observingLifecycle) {
      WidgetsBinding.instance.addObserver(this);
      _observingLifecycle = true;
    }

    notifyListeners();

    if (isPaired) {
      _startTicker();
      await registerPush();
      // The activity may have been dismissed or retired since the app last
      // ran, in which case this starts a new one; when it is still up, this
      // re-registers its token, since the host may have been re-paired or
      // restored in the meantime.
      await _restoreLiveActivity();
      // A registration also triggers a status push from the host; when the
      // token was already registered, ask explicitly so the UI is fresh.
      await requestStatus();
      // And fill in the chart behind it. A phone that was off overnight, or
      // one that has just been paired, has nothing for the longer spans until
      // the host is asked.
      await requestHistoryIfNeeded();
    }
  }

  @override
  void dispose() {
    _stopTicker();
    if (_observingLifecycle) {
      WidgetsBinding.instance.removeObserver(this);
      _observingLifecycle = false;
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (!isPaired) return;
      _startTicker();
      // Status pushes are silent background pushes, which the system drops or
      // defers while the app is not running, so what is on screen right after
      // a resume can be many minutes old.
      unawaited(_syncIfStale());
      // Same for the Lock Screen, which may have been dismissed or retired
      // while the app was away — and which nothing else would bring back.
      unawaited(_restoreLiveActivity());
    } else {
      _stopTicker();
    }
  }

  Future<void> completePairing(PairingBundle newBundle) async {
    await _store.savePairing(newBundle);
    bundle = newBundle;
    snapshot = null;
    // A different host's readings have no business on this chart.
    readingHistory = ReadingHistory.empty;
    await ReadingHistoryStore.clear();
    await StatusService.clearPersisted();
    _rebuildServices();
    _scheduler.reset();
    _registeredLiveActivityToken = null;
    // A new host means a new activity; whatever the user did with the last
    // one has nothing to say about this one.
    _liveActivityDismissedByUser = false;
    liveActivityRunning = false;
    _startTicker();
    notifyListeners();
    await WidgetBridge.clear();
    await LiveActivityBridge.stop();
    await registerPush(force: true);
  }

  Future<void> unpair() async {
    await _store.clear();
    await StatusService.clearPersisted();
    await ReadingHistoryStore.clear();
    bundle = null;
    snapshot = null;
    readingHistory = ReadingHistory.empty;
    // The number belonged to the host that was just unpaired; leaving it would
    // offer to call a stranger from the next pairing's alarm banner.
    await setHostContact(null);
    _rebuildServices();
    _scheduler.reset();
    _registeredLiveActivityToken = null;
    _liveActivityDismissedByUser = false;
    liveActivityRunning = false;
    _stopTicker();
    notifyListeners();
    await WidgetBridge.clear();
    await LiveActivityBridge.stop();
  }

  /// Registers this device's push address with the host so it can deliver
  /// encrypted status snapshots. No-op when the token hasn't changed.
  Future<void> registerPush({bool force = false}) async {
    final service = _commandService;
    final currentBundle = bundle;
    if (service == null || currentBundle == null) return;

    await _push.requestPermission();
    final token = await _push.token;
    if (token == null || token.isEmpty) {
      statusHint = 'Push notifications are unavailable on this device, so live '
          'status from the host cannot be received.';
      notifyListeners();
      return;
    }

    final version = await _push.appVersion;
    // An app update keeps the push token, so the version has to be part of what
    // decides whether the host still knows this follower correctly.
    if (!force &&
        await _store.registeredPushToken == token &&
        await _store.registeredAppVersion == version) {
      return;
    }

    final record = await service.send(TrioCommand.registerFollower(
      pushToken: token,
      pushTransport: _push.transport,
      pushBundleId: await _push.bundleId,
      pushEnvironment: _push.environment,
      appVersion: version,
      appBuild: await _push.appBuild,
      appPlatform: _push.platform,
    ));
    if (record.accepted) {
      await _store.setRegisteredPushToken(token);
      await _store.setRegisteredAppVersion(version);
      statusHint = null;
    } else {
      statusHint = 'Could not register with the host yet: ${record.detail}';
    }
    notifyListeners();
  }

  /// Asks the host for a fresh snapshot and waits briefly for it to arrive.
  ///
  /// Used both by pull-to-refresh and by the app itself when a push has not
  /// arrived in time; a request already in flight is never doubled up.
  Future<void> requestStatus() async {
    final service = _commandService;
    if (service == null || _statusRequestInFlight) return;

    _statusRequestInFlight = true;
    _scheduler.recordRequest(DateTime.now());
    try {
      final before = snapshot?.timestamp;
      final record = await service.send(TrioCommand.statusRequest());
      if (!record.accepted) {
        _scheduler.recordFailure();
        statusHint = 'Could not reach the host: ${record.detail}';
        notifyListeners();
        return;
      }

      // Wait up to 15 s for the answering push.
      final arrived = await _waitForSnapshotChange(since: before, timeout: const Duration(seconds: 15));
      if (arrived) {
        _scheduler.recordSuccess();
        statusHint = null;
      } else {
        _scheduler.recordFailure();
        statusHint = 'The host has not answered yet. It may be offline — the '
            'status will update as soon as it reconnects.';
      }
      notifyListeners();
    } finally {
      _statusRequestInFlight = false;
    }
  }

  /// Asks the host for a snapshot when none has been pushed for a while. Free
  /// in the normal case: as long as pushes keep arriving, the scheduler finds
  /// the status fresh and nothing is sent.
  Future<void> _syncIfStale() async {
    if (!isPaired || _statusRequestInFlight) return;
    if (!_scheduler.shouldRequest(now: DateTime.now(), snapshotAt: snapshot?.timestamp)) return;
    await requestStatus();
  }

  /// Runs only while the app is on screen — a Dart timer does not fire once
  /// the app is suspended, and the host keeps the widgets and the Live
  /// Activity current from its side in the meantime.
  void _startTicker() {
    _ticker?.cancel();
    _ticker = Timer.periodic(_tickInterval, (_) {
      // The freshness line is relative to now, so it needs a rebuild even when
      // no new snapshot arrived.
      notifyListeners();
      unawaited(_syncIfStale());
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
  }

  /// Emergency stop. Sends the suspend command and remembers that it was sent.
  ///
  /// Whether insulin actually stopped is not decided here: it is read from the
  /// host's next status snapshot, which reports the pump's own state. An
  /// accepted push means Apple took the message, nothing more.
  Future<CommandRecord?> suspendInsulin() async {
    commandError = null;
    final record = await sendCommand(TrioCommand.suspendInsulin());
    if (record != null && record.accepted) {
      suspendRequestedAt = DateTime.now();
      notifyListeners();
      // Ask for status straight away rather than waiting for the host's own
      // push, so the screen stops saying "waiting" as soon as it can.
      unawaited(requestStatus());
    }
    return record;
  }

  Future<CommandRecord?> sendCommand(TrioCommand command) async {
    final service = _commandService;
    if (service == null) return null;
    final record = await service.send(command);
    history.insert(0, record);
    if (history.length > 50) {
      history = history.sublist(0, 50);
    }
    await _saveHistory();
    notifyListeners();
    return record;
  }

  // MARK: incoming pushes

  Future<void> _handlePushData(Map<String?, Object?> data) async {
    final statusService = _statusService;
    final currentBundle = bundle;
    if (statusService == null || currentBundle == null) return;

    final followerId = data['follower_id'];
    if (followerId is String && followerId != currentBundle.followerId) return;

    final failure = data['command_error'];
    if (failure is String && failure.isNotEmpty) {
      commandError = failure;
      // Also on the status card, so a rejected temp target or bolus — which
      // have no banner of their own — is not silent either.
      statusHint = failure;
      notifyListeners();
      return;
    }

    final update = data['update_available'];
    if (update is String && update.isNotEmpty) {
      updateAvailableVersion = update;
      notifyListeners();
      return;
    }

    final hostUpdate = data['encrypted_host_update'];
    if (hostUpdate is String && hostUpdate.isNotEmpty) {
      await _handleHostUpdate(hostUpdate);
      return;
    }

    final encrypted = data['encrypted_status'];
    if (encrypted is! String || encrypted.isEmpty) return;

    final updated = await statusService.handleEncryptedStatus(encrypted, current: snapshot);
    if (updated == null) {
      // Not a status. A history slice rides the same field, so that a host
      // sending one to a follower that predates the backfill is ignored rather
      // than misread.
      await _handleHistorySlice(statusService, encrypted);
      return;
    }
    snapshot = updated;
    readingHistory = readingHistory.merge(updated);
    await ReadingHistoryStore.save(readingHistory);
    // Keep the securely stored AI credentials current: the host may have
    // added, rotated or removed them since pairing.
    await _syncAiConfig(updated.ai);
    // Once the host reports insulin running again, the pending marker has
    // served its purpose; leaving it would make a resumed pump look pending.
    if (!updated.suspended && suspendRequestedAt != null && updated.suspendAcknowledged) {
      suspendRequestedAt = null;
    }
    statusHint = null;
    // Pushes are getting through; no need to ask the host for anything.
    _scheduler.recordSuccess();
    notifyListeners();
    // Pushes are also delivered in the background, so the widgets and the
    // Live Activity stay current without the app being opened.
    await WidgetBridge.publish(updated, preferences: displayPreferences);
    await _publishLiveActivity(updated);
  }

  /// Folds one slice of a backfill into the rolling history.
  ///
  /// Slices are merged by timestamp and carry no state, so they can arrive out
  /// of order, late, or partially without leaving the chart inconsistent — the
  /// worst a lost slice costs is a gap, which the chart already draws honestly.
  Future<void> _handleHistorySlice(StatusService statusService, String encrypted) async {
    final slice = await statusService.handleEncryptedHistory(encrypted);
    if (slice == null) return;

    _historySlicesOutstanding = slice.isLast ? 0 : slice.total - slice.sequence;

    if (slice.readings.isNotEmpty) {
      readingHistory = readingHistory.mergeHistory(slice.readings);
      await ReadingHistoryStore.save(readingHistory);
    }
    notifyListeners();
  }

  /// Folds the AI configuration a snapshot carried into the securely stored
  /// pairing bundle. A snapshot without one means the host turned the feature
  /// off (or removed its key), so the stored copy is cleared too — the
  /// follower should not keep searching on a revoked credential.
  Future<void> _syncAiConfig(AiConfig? ai) async {
    final currentBundle = bundle;
    if (currentBundle == null || currentBundle.ai == ai) return;
    final newBundle = currentBundle.withAi(ai);
    await _store.updatePairing(newBundle);
    bundle = newBundle;
  }

  /// The paired host moved Trio to a new phone: point commands at the new
  /// device's push address. Nothing else about the pairing changes — same
  /// secret, same credentials, same sequence counter (the new host carried
  /// this follower's replay state over, so the counter must NOT reset).
  Future<void> _handleHostUpdate(String encrypted) async {
    final service = _hostMigrationService;
    final currentBundle = bundle;
    if (service == null || currentBundle == null) return;

    final update = await service.handleEncryptedHostUpdate(
      encrypted,
      lastApplied: await _store.hostUpdatedAt,
    );
    if (update == null) return;

    final newBundle = update.applyTo(currentBundle);
    await _store.updatePairing(newBundle);
    await _store.setHostUpdatedAt(update.timestamp);
    bundle = newBundle;
    _rebuildServices();
    statusHint = '${newBundle.hostName} moved Trio to a new phone. '
        'This follower switched over automatically.';
    notifyListeners();

    // Tell the new host this device's current push address and version —
    // the migrated registration may be stale — and refresh the screen from
    // the new device.
    await registerPush(force: true);
    unawaited(requestStatus());
  }

  Future<bool> _waitForSnapshotChange({DateTime? since, required Duration timeout}) async {
    final completer = Completer<bool>();
    void listener() {
      final current = snapshot?.timestamp;
      if (current != null && (since == null || current.isAfter(since))) {
        if (!completer.isCompleted) completer.complete(true);
      }
    }

    addListener(listener);
    // Check immediately in case the push already landed.
    listener();
    final result = await completer.future
        .timeout(timeout, onTimeout: () => false);
    removeListener(listener);
    return result;
  }

  /// Turns the Live Activity on or off, starting or ending it immediately so
  /// the switch has a visible effect.
  Future<void> setLiveActivityEnabled(bool enabled) async {
    liveActivityEnabled = enabled;
    // Switching it on is as clear a request for it back as the restart button.
    if (enabled) _liveActivityDismissedByUser = false;
    notifyListeners();
    await LiveActivityBridge.setEnabled(enabled);
    if (enabled) {
      await _publishLiveActivity(snapshot);
    } else {
      liveActivityRunning = false;
      notifyListeners();
    }
  }

  /// Starts a fresh activity, replacing any that is still running.
  ///
  /// The way back after the Lock Screen was swiped away — and the only one
  /// that works. A dismissed activity cannot be updated back into existence,
  /// and the system only hands out a push token when an activity is
  /// *requested*, so the host has to be given the new one before it can update
  /// anything remotely again.
  Future<void> restartLiveActivity() async {
    if (!liveActivityEnabled) return;
    _liveActivityDismissedByUser = false;
    // The old token died with the old activity. Forget it, so the replacement
    // is registered even if the host was never told the first one had gone.
    _registeredLiveActivityToken = null;

    await LiveActivityBridge.restart(
      snapshot,
      hostName: _hostName,
      preferences: displayPreferences,
    );
    liveActivityRunning = await LiveActivityBridge.isRunning();
    notifyListeners();

    // The token usually turns up on the stream a moment later, but ask as
    // well in case the system had one ready straight away.
    await _handleLiveActivityToken(await LiveActivityBridge.pushToken());
  }

  /// Puts the Lock Screen back, and keeps what is on it honest.
  ///
  /// Run whenever the app comes to the front, because that is the first moment
  /// it can find out what happened while it was away: the system retires
  /// activities after a few hours, silent status pushes that would have
  /// refreshed one are dropped at the system's discretion, and neither leaves
  /// any trace the app could have read earlier.
  Future<void> _restoreLiveActivity() async {
    if (!isPaired) return;

    final running = await LiveActivityBridge.isRunning();
    if (running != liveActivityRunning) {
      liveActivityRunning = running;
      notifyListeners();
    }
    if (!liveActivityEnabled) return;

    if (running) {
      // Still up, but possibly showing a reading from before the app was
      // suspended. Republishing refreshes both the content and the stale date
      // the system dims it by.
      await _publishLiveActivity(snapshot);
      // And retries a token registration that failed while the host was
      // unreachable: nothing else would, and until it succeeds the Lock Screen
      // is only ever updated while this app happens to be awake.
      await _handleLiveActivityToken(await LiveActivityBridge.pushToken());
      return;
    }

    if (_liveActivityDismissedByUser) return;
    // Nothing worth putting on the Lock Screen yet; the first snapshot starts
    // one through the ordinary publish path.
    if (snapshot?.latest == null) return;
    await restartLiveActivity();
  }

  /// Puts a snapshot on the Lock Screen, unless the user has swiped it away.
  ///
  /// The bridge would otherwise start a new activity for any snapshot that
  /// found none running — which is exactly the recovery an activity retired by
  /// the system needs, and exactly the wrong answer to one the user just
  /// dismissed.
  Future<void> _publishLiveActivity(StatusSnapshot? updated) async {
    if (_liveActivityDismissedByUser) return;
    await LiveActivityBridge.publish(
      updated,
      hostName: _hostName,
      preferences: displayPreferences,
    );
    final running = await LiveActivityBridge.isRunning();
    if (running == liveActivityRunning) return;
    liveActivityRunning = running;
    notifyListeners();
  }

  /// The activity left the Lock Screen while the app was running.
  void _handleLiveActivityEnded() {
    liveActivityRunning = false;
    _liveActivityDismissedByUser = true;
    // The token goes with it; a new activity will bring a new one.
    _registeredLiveActivityToken = null;
    notifyListeners();
  }

  /// Puts away the host's update notice until it sends another one.
  void dismissUpdateNotice() {
    updateAvailableVersion = null;
    notifyListeners();
  }

  /// Stores new layout choices and redraws everything that follows them.
  ///
  /// The Live Activity is republished rather than merely reloaded: its layout
  /// is read when a content state is rendered, so without a new state it would
  /// keep the old shape until the next reading arrived.
  Future<void> setDisplayPreferences(DisplayPreferences preferences) async {
    displayPreferences = preferences;
    notifyListeners();
    await DisplayPreferencesStore.save(preferences);
    await WidgetBridge.publish(snapshot, preferences: preferences);
    await _publishLiveActivity(snapshot);
  }

  /// Lets the host update the Live Activity directly, or takes that back.
  ///
  /// Switching on restarts the activity: the system only issues a push token
  /// at the moment an activity is requested, so one that is already running
  /// can never gain one.
  Future<void> setLiveActivityRemoteUpdates(bool enabled) async {
    liveActivityRemoteUpdates = enabled;
    notifyListeners();
    await LiveActivityBridge.setRemoteUpdatesEnabled(enabled);

    if (enabled) {
      // Restarting is what mints the token, and it registers the new one.
      await restartLiveActivity();
    } else {
      // Forced: this app may have been restarted since the token was
      // registered, so it cannot tell from memory whether the host still holds
      // one. Withdrawing has to reach the host either way — the activity keeps
      // running, so nothing else would stop the pushes.
      await _sendLiveActivityToken('', force: true);
    }
  }

  /// The system issued, rotated or dropped the Live Activity's push token.
  Future<void> _handleLiveActivityToken(String? token) async {
    if (!liveActivityRemoteUpdates) return;
    await _sendLiveActivityToken(token ?? '');
  }

  /// Registers (or clears) the Live Activity token on the host, skipping the
  /// send when the host already has this exact token.
  Future<void> _sendLiveActivityToken(String token, {bool force = false}) async {
    final service = _commandService;
    if (service == null) return;
    // A null registration and an empty token both mean "the host has nothing".
    if (!force && token == (_registeredLiveActivityToken ?? '')) return;

    final record = await service.send(TrioCommand.registerLiveActivity(liveActivityToken: token));
    if (record.accepted) {
      _registeredLiveActivityToken = token;
    }
  }

  String get _hostName => bundle?.hostName ?? 'Trio';

  void _rebuildServices() {
    final currentBundle = bundle;
    if (currentBundle == null) {
      _commandService = null;
      _statusService = null;
      _hostMigrationService = null;
      return;
    }
    _commandService = CommandService(
      bundle: currentBundle,
      store: _store,
      followerName: currentBundle.followerName,
    );
    _statusService = StatusService(currentBundle.secret);
    _hostMigrationService = HostMigrationService(currentBundle.secret);
  }

  /// Stores (or clears) the number the suspension banner offers to call.
  Future<void> setHostContact(String? number) async {
    final trimmed = number?.trim();
    hostContact = (trimmed == null || trimmed.isEmpty) ? null : trimmed;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (hostContact == null) {
      await prefs.remove(_hostContactKey);
    } else {
      await prefs.setString(_hostContactKey, hostContact!);
    }
  }

  Future<void> _loadHostContact() async {
    final prefs = await SharedPreferences.getInstance();
    hostContact = prefs.getString(_hostContactKey);
  }

  Future<void> _loadHistory() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        history = decoded
            .whereType<Map<String, dynamic>>()
            .map(CommandRecord.fromJson)
            .toList();
      }
    } catch (_) {
      history = [];
    }
  }

  Future<void> _saveHistory() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_historyKey, jsonEncode(history.map((r) => r.toJson()).toList()));
  }
}
