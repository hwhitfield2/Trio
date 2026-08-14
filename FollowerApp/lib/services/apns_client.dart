import 'dart:convert';
import 'dart:io';

import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';
import 'package:http2/http2.dart';

import '../models/pairing_bundle.dart';

class ApnsException implements Exception {
  ApnsException(this.message, {this.status});
  final String message;
  final int? status;

  @override
  String toString() => status == null ? message : 'APNS $status: $message';
}

/// Sends pushes straight to Apple's APNS HTTP/2 API. This works from both iOS
/// and Android — it is a plain HTTPS/2 request authenticated with an ES256
/// provider token signed by the .p8 key received during pairing.
class ApnsClient {
  ApnsClient(this.apns);

  final ApnsInfo apns;

  String? _cachedToken;
  DateTime? _tokenIssuedAt;

  /// Apple requires provider tokens to be refreshed between 20 and 60 minutes;
  /// reuse for 40 minutes.
  static const _tokenLifetime = Duration(minutes: 40);

  String get _host => apns.production ? 'api.push.apple.com' : 'api.sandbox.push.apple.com';

  String _providerToken() {
    final issuedAt = _tokenIssuedAt;
    if (_cachedToken != null && issuedAt != null && DateTime.now().difference(issuedAt) < _tokenLifetime) {
      return _cachedToken!;
    }
    final jwt = JWT({'iss': apns.teamId}, header: {'kid': apns.keyId});
    final token = jwt.sign(ECPrivateKey(apns.apnsKey), algorithm: JWTAlgorithm.ES256);
    _cachedToken = token;
    _tokenIssuedAt = DateTime.now();
    return token;
  }

  /// Sends the encrypted command envelope. Throws [ApnsException] unless APNS
  /// answers 200.
  ///
  /// Pass [alertTitle] and [alertBody] for a command that changes something on
  /// the host: the push then carries a banner naming the follower and what it
  /// asked for, so whoever holds the host phone sees who did what. Omit them
  /// for a status refresh or a registration and the push is silent — the host
  /// still wakes and answers it, without a notification.
  ///
  /// The two kinds of push are also delivered differently, because Apple treats
  /// them differently: an alert push may be shown even when Trio has been force
  /// quit, which is what makes an emergency stop worth sending as one, while a
  /// background push must go out at priority 5 and is delivered at the system's
  /// discretion — acceptable for a refresh that will simply be retried.
  Future<void> send({
    required String encryptedData,
    required String followerId,
    String? alertTitle,
    String? alertBody,
  }) async {
    final silent = alertTitle == null || alertBody == null;
    final body = jsonEncode({
      'aps': {
        if (!silent) ...{
          'alert': {'title': alertTitle, 'body': alertBody},
          'interruption-level': 'time-sensitive',
        },
        // content-available wakes Trio in the background so the command is
        // processed without the user tapping the notification.
        'content-available': 1,
      },
      'encrypted_data': encryptedData,
      'follower_id': followerId,
    });

    final token = _providerToken();

    final socket = await SecureSocket.connect(
      _host,
      443,
      supportedProtocols: ['h2'],
      timeout: const Duration(seconds: 15),
    );
    if (socket.selectedProtocol != 'h2') {
      socket.destroy();
      throw ApnsException('Server did not negotiate HTTP/2');
    }

    final transport = ClientTransportConnection.viaSocket(socket);
    try {
      final bodyBytes = utf8.encode(body);
      final stream = transport.makeRequest(
        [
          Header.ascii(':method', 'POST'),
          Header.ascii(':path', '/3/device/${apns.deviceToken}'),
          Header.ascii(':scheme', 'https'),
          Header.ascii(':authority', _host),
          Header.ascii('authorization', 'bearer $token'),
          Header.ascii('apns-topic', apns.bundleId),
          Header.ascii('apns-push-type', silent ? 'background' : 'alert'),
          // Apple rejects a background push sent at priority 10.
          Header.ascii('apns-priority', silent ? '5' : '10'),
          Header.ascii('apns-expiration', '0'),
          Header.ascii('content-type', 'application/json'),
          Header.ascii('content-length', bodyBytes.length.toString()),
        ],
        endStream: false,
      );
      stream.outgoingMessages.add(DataStreamMessage(bodyBytes, endStream: true));

      int? status;
      final responseBody = StringBuffer();
      await for (final message in stream.incomingMessages) {
        if (message is HeadersStreamMessage) {
          for (final header in message.headers) {
            if (utf8.decode(header.name) == ':status') {
              status = int.tryParse(utf8.decode(header.value));
            }
          }
        } else if (message is DataStreamMessage) {
          responseBody.write(utf8.decode(message.bytes, allowMalformed: true));
        }
      }

      if (status != 200) {
        var reason = responseBody.toString();
        try {
          final decoded = jsonDecode(reason);
          if (decoded is Map && decoded['reason'] is String) {
            reason = _friendlyReason(decoded['reason'] as String);
          }
        } catch (_) {}
        throw ApnsException(reason.isEmpty ? 'Push rejected' : reason, status: status);
      }
    } finally {
      await transport.finish();
    }
  }

  static String _friendlyReason(String reason) {
    switch (reason) {
      case 'BadDeviceToken':
        return 'The host device token is no longer valid. Re-pair with the Trio host.';
      case 'ExpiredProviderToken':
      case 'InvalidProviderToken':
        return 'Push authentication failed. Check the APNS key on the Trio host and re-pair.';
      case 'TopicDisallowed':
      case 'DeviceTokenNotForTopic':
        return 'The push topic does not match the Trio app. Re-pair with the Trio host.';
      case 'Unregistered':
        return 'The Trio host is no longer registered for push notifications.';
      default:
        return reason;
    }
  }
}
