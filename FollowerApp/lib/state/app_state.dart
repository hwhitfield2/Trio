import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/command.dart';
import '../models/pairing_bundle.dart';
import '../services/command_service.dart';
import '../services/nightscout_service.dart';
import '../services/pairing_store.dart';

class AppState extends ChangeNotifier {
  AppState({PairingStore? store}) : _store = store ?? PairingStore();

  final PairingStore _store;

  PairingBundle? bundle;
  CommandService? _commandService;
  NightscoutService? _nightscout;

  bool initialized = false;
  List<GlucoseEntry> entries = const [];
  NightscoutStatus status = const NightscoutStatus();
  String? statusError;
  List<CommandRecord> history = [];

  static const _historyKey = 'trio_follower.history';

  bool get isPaired => bundle != null;
  bool get hasNightscout => bundle?.nightscout != null;

  Future<void> initialize() async {
    bundle = await _store.loadPairing();
    _rebuildServices();
    await _loadHistory();
    initialized = true;
    notifyListeners();
    if (hasNightscout) {
      await refreshStatus();
    }
  }

  Future<void> completePairing(PairingBundle newBundle) async {
    await _store.savePairing(newBundle);
    bundle = newBundle;
    _rebuildServices();
    notifyListeners();
    if (hasNightscout) {
      await refreshStatus();
    }
  }

  Future<void> unpair() async {
    await _store.clear();
    bundle = null;
    _rebuildServices();
    entries = const [];
    status = const NightscoutStatus();
    notifyListeners();
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

  Future<void> refreshStatus() async {
    final nightscout = _nightscout;
    if (nightscout == null) return;
    try {
      final results = await Future.wait([
        nightscout.fetchEntries(),
        nightscout.fetchStatus(),
      ]);
      entries = results[0] as List<GlucoseEntry>;
      status = results[1] as NightscoutStatus;
      statusError = null;
    } catch (error) {
      statusError = 'Could not reach Nightscout: $error';
    }
    notifyListeners();
  }

  void _rebuildServices() {
    final currentBundle = bundle;
    if (currentBundle == null) {
      _commandService = null;
      _nightscout = null;
      return;
    }
    _commandService = CommandService(
      bundle: currentBundle,
      store: _store,
      followerName: currentBundle.followerName,
    );
    final nightscoutInfo = currentBundle.nightscout;
    _nightscout = nightscoutInfo == null ? null : NightscoutService(nightscoutInfo);
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
