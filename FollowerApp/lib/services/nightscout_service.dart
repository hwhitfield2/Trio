import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../models/pairing_bundle.dart';

class GlucoseEntry {
  const GlucoseEntry({required this.sgv, required this.date, this.direction});

  /// mg/dL
  final int sgv;
  final DateTime date;
  final String? direction;

  String get trendArrow {
    switch (direction) {
      case 'DoubleUp':
        return '⇈';
      case 'SingleUp':
        return '↑';
      case 'FortyFiveUp':
        return '↗';
      case 'Flat':
        return '→';
      case 'FortyFiveDown':
        return '↘';
      case 'SingleDown':
        return '↓';
      case 'DoubleDown':
        return '⇊';
      default:
        return '';
    }
  }
}

class NightscoutStatus {
  const NightscoutStatus({this.iob, this.cob});
  final double? iob;
  final double? cob;
}

/// Read-only Nightscout client used for the follow/status display. Command
/// delivery never goes through Nightscout — commands travel end-to-end
/// encrypted over APNS.
class NightscoutService {
  NightscoutService(this.info, {http.Client? client}) : _client = client ?? http.Client();

  final NightscoutInfo info;
  final http.Client _client;

  Map<String, String> get _headers {
    final secret = info.apiSecret;
    if (secret == null || secret.isEmpty) return const {};
    return {'api-secret': sha1.convert(utf8.encode(secret)).toString()};
  }

  Uri _uri(String path, [Map<String, String>? query]) {
    final base = info.url.endsWith('/') ? info.url.substring(0, info.url.length - 1) : info.url;
    return Uri.parse('$base$path').replace(queryParameters: query);
  }

  Future<List<GlucoseEntry>> fetchEntries({int count = 48}) async {
    final response = await _client
        .get(_uri('/api/v1/entries/sgv.json', {'count': '$count'}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('Nightscout responded with ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .where((e) => e['sgv'] is num && e['date'] is num)
        .map(
          (e) => GlucoseEntry(
            sgv: (e['sgv'] as num).round(),
            date: DateTime.fromMillisecondsSinceEpoch((e['date'] as num).round()),
            direction: e['direction'] as String?,
          ),
        )
        .toList();
  }

  Future<NightscoutStatus> fetchStatus() async {
    final response = await _client
        .get(_uri('/api/v1/devicestatus.json', {'count': '10'}), headers: _headers)
        .timeout(const Duration(seconds: 15));
    if (response.statusCode != 200) return const NightscoutStatus();
    final decoded = jsonDecode(response.body);
    if (decoded is! List) return const NightscoutStatus();

    double? iob;
    double? cob;
    for (final entry in decoded.whereType<Map<String, dynamic>>()) {
      final openaps = entry['openaps'];
      if (openaps is! Map<String, dynamic>) continue;
      final suggested = (openaps['suggested'] ?? openaps['enacted']);
      if (suggested is! Map<String, dynamic>) continue;
      iob ??= (suggested['IOB'] as num?)?.toDouble();
      cob ??= (suggested['COB'] as num?)?.toDouble();
      if (iob != null && cob != null) break;
    }
    return NightscoutStatus(iob: iob, cob: cob);
  }
}
