import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import 'trio_controls.dart';

/// Shows a confirmation sheet for a command, requires biometric/passcode
/// confirmation where the device supports it, sends the command and reports
/// the outcome. Returns true when the command was accepted by the push
/// service.
///
/// For commands with no screen of their own — the two cancellations — where
/// the sheet is the only place the command is ever written down. Anything
/// entered on a screen that already shows its amount full-size confirms with
/// [authenticateAndSend] instead, so a command is never held for twice.
Future<bool> confirmAndSend(BuildContext context, TrioCommand command) async {
  final colors = TrioTheme.of(context);
  final confirmed = await showModalBottomSheet<bool>(
        context: context,
        backgroundColor: colors.panel,
        // Square, full-bleed, and flush with the bottom of the screen: this is
        // a panel that rose from the foot of the app, not a floating card.
        shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
        builder: (sheetContext) => _ConfirmSheet(command: command),
      ) ??
      false;
  if (!confirmed || !context.mounted) return false;
  return authenticateAndSend(context, command);
}

/// Takes the biometric confirmation and sends, without a sheet.
///
/// The caller has already made the command explicit — a bolus screen showing
/// "1.20 U" at 78 points, held down until the button filled — and repeating
/// that back in a sheet buys nothing but a second gesture in an emergency.
/// The Face ID prompt still names what is being sent.
Future<bool> authenticateAndSend(BuildContext context, TrioCommand command) async {
  final colors = TrioTheme.of(context);
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
    // Devices with no protection configured fall through to the deliberate
    // hold the caller already took.
  }
  if (!context.mounted) return false;

  final state = context.read<AppState>();
  final messenger = ScaffoldMessenger.of(context);

  final record = await state.sendCommand(command);
  if (record == null) return false;

  messenger.showSnackBar(
    SnackBar(
      content: Text(
        record.accepted
            ? 'Sent: ${record.description}'
            : 'Failed: ${record.detail ?? 'unknown error'}',
      ),
      backgroundColor: record.accepted ? null : colors.dangerDeep,
    ),
  );
  return record.accepted;
}

/// The last thing between a follower and someone else's pump: what is being
/// sent, in what amount, to which phone, as whom, and over what.
class _ConfirmSheet extends StatelessWidget {
  const _ConfirmSheet({required this.command});

  final TrioCommand command;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.read<AppState>();
    final bundle = state.bundle;
    final amount = command.amountLabel;

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 44,
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.hairline)),
            ),
            padding: const EdgeInsets.only(left: TrioMetrics.inset, right: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'CONFIRM COMMAND',
                    style: TrioType.micro(color: colors.inkFaint, size: 10.5),
                  ),
                ),
                Semantics(
                  button: true,
                  label: 'Cancel',
                  child: InkWell(
                    onTap: () => Navigator.of(context).pop(false),
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: Icon(Icons.close, size: 20, color: colors.inkMuted),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
            child: Column(
              children: [
                _ConfirmRow(
                  label: 'Action',
                  child: Text(
                    command.actionLabel,
                    style: TrioType.title(color: colors.ink, size: 15),
                  ),
                ),
                if (amount != null)
                  _ConfirmRow(
                    label: 'Amount',
                    child: Text(
                      amount,
                      style: TrioType.numeral(
                        size: 17,
                        weight: FontWeight.w600,
                        color: colors.ink,
                      ),
                    ),
                  ),
                if (bundle != null) ...[
                  _ConfirmRow(
                    label: 'To',
                    child: Text(
                      bundle.hostName,
                      style: TrioType.label(color: colors.ink, size: 14),
                    ),
                  ),
                  _ConfirmRow(
                    label: 'As',
                    child: Text(
                      bundle.followerName,
                      style: TrioType.label(color: colors.ink, size: 14),
                    ),
                  ),
                ],
                _ConfirmRow(
                  label: 'Channel',
                  divider: false,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.lock, size: 15, color: TrioColors.inRange),
                      const SizedBox(width: 8),
                      Text(
                        'AES-256-GCM',
                        style: TrioType.numeral(
                          size: 12,
                          color: colors.ink,
                          tracking: 0.04,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const TrioNote(
            text: 'The host applies its own safety checks before acting. It pushes a '
                'fresh status right after, so you see the effect rather than just '
                'the send.',
            padding: EdgeInsets.fromLTRB(TrioMetrics.inset, 8, TrioMetrics.inset, 16),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 22),
            child: TrioHoldButton(
              label: 'Hold to send',
              onCompleted: () => Navigator.of(context).pop(true),
            ),
          ),
        ],
      ),
    );
  }
}

/// One line of the sheet: a mono caption on the left, the value on the right.
class _ConfirmRow extends StatelessWidget {
  const _ConfirmRow({required this.label, required this.child, this.divider = true});

  final String label;
  final Widget child;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      constraints: const BoxConstraints(minHeight: 44),
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label.toUpperCase(),
              style: TrioType.micro(
                color: colors.inkFaint,
                size: 10,
                weight: FontWeight.w400,
                tracking: 0.14,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Flexible(child: Align(alignment: Alignment.centerRight, child: child)),
        ],
      ),
    );
  }
}
