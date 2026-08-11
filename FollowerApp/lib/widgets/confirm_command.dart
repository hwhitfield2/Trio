import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';

/// Shows a confirmation sheet for a command, requires biometric/passcode
/// confirmation where the device supports it, sends the command and reports
/// the outcome. Returns true when the command was accepted by the push
/// service.
Future<bool> confirmAndSend(BuildContext context, TrioCommand command) async {
  final confirmed = await showModalBottomSheet<bool>(
        context: context,
        showDragHandle: true,
        builder: (sheetContext) => _ConfirmSheet(command: command),
      ) ??
      false;
  if (!confirmed || !context.mounted) return false;

  final auth = LocalAuthentication();
  try {
    final canAuth = await auth.isDeviceSupported();
    if (canAuth) {
      final ok = await auth.authenticate(
        localizedReason: 'Confirm sending: ${command.describe()}',
        options: const AuthenticationOptions(stickyAuth: true),
      );
      if (!ok) return false;
    }
  } catch (_) {
    // Devices without any protection fall through to the explicit
    // confirmation already given in the sheet.
  }
  if (!context.mounted) return false;

  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);
  final errorColor = Theme.of(context).colorScheme.error;

  final record = await state.sendCommand(command);
  if (record == null) return false;

  messenger.showSnackBar(
    SnackBar(
      content: Text(
        record.accepted
            ? 'Sent: ${record.description}'
            : 'Failed: ${record.detail ?? 'unknown error'}',
      ),
      backgroundColor: record.accepted ? null : errorColor,
    ),
  );
  return record.accepted;
}

class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.command});

  final TrioCommand command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Icon(Icons.send_to_mobile, size: 40, color: theme.colorScheme.primary),
            const SizedBox(height: 12),
            Text(
              'Send remote command?',
              style: theme.textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              command.describe(),
              style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'The command is encrypted and delivered to the Trio host, which '
              'applies its own safety checks before acting.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm and send'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}
