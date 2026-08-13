import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

/// The emergency stop, and the state it leaves behind.
///
/// Deliberately unlike the other actions on this screen. Those ask the host to
/// do something and are done; this one stops insulin and *stays* stopped until
/// someone holding the host phone answers an alarm. So it is guarded on the way
/// in, and once used it keeps a live account of what is happening on screen.
class BreakGlassButton extends StatelessWidget {
  const BreakGlassButton({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return OutlinedButton.icon(
      onPressed: () => _confirm(context),
      icon: const Icon(Icons.pan_tool),
      label: const Text('Suspend all insulin'),
      style: OutlinedButton.styleFrom(
        foregroundColor: theme.colorScheme.error,
        side: BorderSide(color: theme.colorScheme.error),
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
  }

  Future<void> _confirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => const _BreakGlassDialog(),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;

    // Same biometric gate as every other command. It is not there to slow an
    // emergency down — it is one tap — but an insulin stop that a pocket can
    // trigger would be its own hazard.
    final auth = LocalAuthentication();
    try {
      if (await auth.isDeviceSupported()) {
        final ok = await auth.authenticate(
          localizedReason: 'Confirm suspending all insulin delivery',
          options: const AuthenticationOptions(stickyAuth: true),
        );
        if (!ok) return;
      }
    } catch (_) {
      // No device protection configured: the explicit confirmation above stands.
    }
    if (!context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final record = await context.read<AppState>().suspendInsulin();
    if (record == null) return;

    messenger.showSnackBar(
      SnackBar(
        content: Text(
          record.accepted
              // Carefully not "insulin suspended": all that is known here is
              // that Apple took the message. Whether the pump actually stopped
              // arrives with the host's next status.
              ? 'Sent to the host. Waiting for it to confirm insulin has stopped.'
              : 'Could not reach the host: ${record.detail ?? 'unknown error'}',
        ),
        backgroundColor: record.accepted ? null : errorColor,
        duration: const Duration(seconds: 6),
      ),
    );
  }
}

class _BreakGlassDialog extends StatelessWidget {
  const _BreakGlassDialog();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      icon: Icon(Icons.warning_amber, color: theme.colorScheme.error, size: 36),
      title: const Text('Suspend all insulin?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This stops all insulin delivery on the host — basal and automated '
            'dosing alike — and sounds a repeating alarm on that phone.',
          ),
          const SizedBox(height: 12),
          Text(
            'Delivery stays stopped until someone there answers the alarm. '
            'Nothing restarts it automatically, so if nobody answers, reach '
            'them another way: hours without insulin carry their own danger.',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: theme.colorScheme.error),
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Suspend insulin'),
        ),
      ],
    );
  }
}

/// The live account of an emergency suspension, shown at the top of the home
/// screen while one is in force.
class SuspensionBanner extends StatelessWidget {
  const SuspensionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final snapshot = state.snapshot;
    final requestedAt = state.suspendRequestedAt;

    // Asked for, but the host has not yet reported a stopped pump.
    if (snapshot?.suspended != true) {
      if (requestedAt == null) return const SizedBox.shrink();
      return _Banner(
        color: theme.colorScheme.tertiaryContainer,
        onColor: theme.colorScheme.onTertiaryContainer,
        icon: Icons.hourglass_top,
        title: 'Suspend requested',
        body: 'Waiting for the host to confirm that insulin has stopped. It has '
            'not confirmed yet — assume insulin is still running.',
      );
    }

    final suspendedAt = snapshot!.suspendedAt ?? requestedAt;
    final elapsed = suspendedAt == null ? null : DateTime.now().difference(suspendedAt);
    final since = suspendedAt == null ? '' : ' since ${DateFormat.jm().format(suspendedAt)}';
    final duration = elapsed == null ? '' : ' · ${_describe(elapsed)}';

    if (snapshot.suspendAcknowledged) {
      return _Banner(
        color: theme.colorScheme.secondaryContainer,
        onColor: theme.colorScheme.onSecondaryContainer,
        icon: Icons.check_circle,
        title: 'Insulin suspended · acknowledged',
        body: 'Someone on the host answered the alarm and chose to leave '
            'delivery stopped$since.$duration',
      );
    }

    return _Banner(
      color: theme.colorScheme.errorContainer,
      onColor: theme.colorScheme.onErrorContainer,
      icon: Icons.pan_tool,
      title: 'Insulin suspended · not acknowledged',
      body: 'Nobody on the host has answered the alarm$since.$duration '
          'If they do not answer, reach them another way.',
    );
  }

  static String _describe(Duration duration) {
    if (duration.inMinutes < 1) return 'just now';
    if (duration.inMinutes < 60) return '${duration.inMinutes} min';
    return '${duration.inHours} h ${duration.inMinutes % 60} min';
  }
}

class _Banner extends StatelessWidget {
  const _Banner({
    required this.color,
    required this.onColor,
    required this.icon,
    required this.title,
    required this.body,
  });

  final Color color;
  final Color onColor;
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: onColor),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: onColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(body, style: theme.textTheme.bodySmall?.copyWith(color: onColor)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
