import '../models/command.dart';
import '../models/pairing_bundle.dart';
import 'apns_client.dart';
import 'pairing_store.dart';
import 'secure_messenger.dart';

/// Encrypts and delivers commands to the paired Trio host.
class CommandService {
  CommandService({
    required this.bundle,
    required this.store,
    required this.followerName,
    ApnsClient? apnsClient,
  })  : _apns = apnsClient ?? ApnsClient(bundle.apns),
        _messenger = SecureMessenger(bundle.secret);

  final PairingBundle bundle;
  final PairingStore store;
  final String followerName;
  final ApnsClient _apns;
  final SecureMessenger _messenger;

  /// Sends a command. Returns a record for the history list; throws only on
  /// programmer error — transport failures are captured in the record.
  Future<CommandRecord> send(TrioCommand command) async {
    final sequence = await store.nextSequence();
    final payload = command.toPayload(user: followerName, sequence: sequence);
    final encrypted = await _messenger.encrypt(payload);

    try {
      await _apns.send(encryptedData: encrypted, followerId: bundle.followerId);
      return CommandRecord(
        description: command.describe(),
        sentAt: DateTime.now(),
        accepted: true,
        detail: 'Delivered to Apple push service',
      );
    } on ApnsException catch (error) {
      return CommandRecord(
        description: command.describe(),
        sentAt: DateTime.now(),
        accepted: false,
        detail: error.toString(),
      );
    } catch (error) {
      return CommandRecord(
        description: command.describe(),
        sentAt: DateTime.now(),
        accepted: false,
        detail: 'Network error: $error',
      );
    }
  }
}
