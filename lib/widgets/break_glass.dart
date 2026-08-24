import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../state/app_state.dart';
import '../theme/trio_design.dart';
import 'trio_controls.dart';

/// Asks for an insulin suspension, behind the guard sheet and the biometric
/// gate. Returns true when the command was accepted for delivery.
///
/// Deliberately unlike the other actions. Those ask the host to do something
/// and are done; this one stops insulin and *stays* stopped until someone
/// holding the host phone answers an alarm. So it is guarded on the way in,
/// and once used the home screen keeps a live account of what is happening.
Future<bool> confirmSuspend(BuildContext context) async {
  final confirmed = await showModalBottomSheet<bool>(
        context: context,
        isScrollControlled: true,
        backgroundColor: TrioTheme.of(context).panel,
        shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
        builder: (sheetContext) => const _SuspendGuard(),
      ) ??
      false;
  if (!confirmed || !context.mounted) return false;

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
      if (!ok) return false;
    }
  } catch (_) {
    // No device protection configured: the explicit confirmation above stands.
  }
  if (!context.mounted) return false;

  final messenger = ScaffoldMessenger.of(context);
  final colors = TrioTheme.of(context);
  final record = await context.read<AppState>().suspendInsulin();
  if (record == null) return false;

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
      backgroundColor: record.accepted ? null : colors.dangerDeep,
      duration: const Duration(seconds: 6),
    ),
  );
  return record.accepted;
}

/// The three things a follower has to have read before insulin stops.
class _SuspendGuard extends StatelessWidget {
  const _SuspendGuard();

  static const _consequences = [
    'Delivery stays stopped until someone there answers the alarm.',
    'Nothing restarts it automatically — not the loop, not a timer.',
    'If nobody answers, reach them another way. Hours without insulin '
        'carry their own danger.',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: colors.dangerDeep,
            padding: const EdgeInsets.all(TrioMetrics.inset),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber, size: 18, color: colors.onDangerDeep),
                    const SizedBox(width: 8),
                    Text(
                      'SUSPEND ALL INSULIN',
                      style: TrioType.micro(color: colors.onDangerDeep, size: 10.5),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  'This stops basal and automated dosing on the host phone, and '
                  'sounds a repeating alarm there.',
                  style: TrioType.title(
                    color: colors.onDangerDeep,
                    size: 17,
                    height: 1.35,
                    tracking: -0.0147,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
            child: Column(
              children: [
                for (var index = 0; index < _consequences.length; index++)
                  Container(
                    decoration: index == _consequences.length - 1
                        ? null
                        : BoxDecoration(
                            border: Border(
                              bottom: BorderSide(color: colors.hairlineSoft),
                            ),
                          ),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 18,
                          child: Text(
                            '0${index + 1}',
                            style: TrioType.numeral(
                              size: 11,
                              weight: FontWeight.w600,
                              color: colors.inkFaint,
                            ),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _consequences[index],
                            style: TrioType.body(color: colors.ink, size: 13.5, height: 1.5),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 12, 22),
            child: Column(
              children: [
                TrioHoldButton(
                  label: 'Hold 3 s to suspend',
                  // Three seconds, not the usual fraction of one. Every other
                  // hold in the app guards against a brush; this one has to
                  // outlast a moment of doubt as well.
                  hold: const Duration(seconds: 3),
                  background: colors.dangerDeep,
                  foreground: colors.onDangerDeep,
                  onCompleted: () => Navigator.of(context).pop(true),
                ),
                const SizedBox(height: 8),
                SizedBox(
                  height: 48,
                  child: Semantics(
                    button: true,
                    label: 'Cancel',
                    excludeSemantics: true,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => Navigator.of(context).pop(false),
                      child: Center(
                        child: Text(
                          'CANCEL',
                          style: TrioType.micro(
                            color: colors.inkMuted,
                            size: 11,
                            tracking: 0.14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The live account of an emergency suspension, shown above everything else on
/// the home screen while one is in force — including above the reading, since
/// stopped insulin outranks any number on the screen.
class SuspensionBanner extends StatefulWidget {
  const SuspensionBanner({super.key});

  @override
  State<SuspensionBanner> createState() => _SuspensionBannerState();
}

class _SuspensionBannerState extends State<SuspensionBanner> {
  Timer? _ticker;

  /// The elapsed clock counts in seconds, so it needs a beat of its own: the
  /// app's own tick is half a minute, which would make a running count look
  /// stuck. Only runs while there is actually a clock on screen.
  void _syncTicker({required bool running}) {
    if (running == (_ticker != null)) return;
    if (running) {
      _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final colors = TrioTheme.of(context);
    final snapshot = state.snapshot;
    final requestedAt = state.suspendRequestedAt;

    // Asked for, but the host has not yet reported a stopped pump.
    if (snapshot?.suspended != true) {
      _syncTicker(running: false);
      if (requestedAt == null) return const SizedBox.shrink();

      final waiting = DateTime.now().difference(requestedAt);
      final error = state.commandError;

      // The host said no, or could not do it.
      if (error != null) {
        return _AlertPanel(
          icon: Icons.error,
          heading: 'INSULIN WAS NOT SUSPENDED',
          body: '$error Insulin is still running.',
          background: colors.dangerDeep,
          onBackground: colors.onDangerDeep,
        );
      }

      // Nothing came back. After a minute this has stopped being "in flight"
      // and started being "no answer", and saying so is the difference between
      // waiting and going to check on someone.
      if (waiting.inSeconds >= 60) {
        return _AlertPanel(
          icon: Icons.help,
          heading: 'NO ANSWER FROM THE HOST',
          body: 'Asked ${_describe(waiting)} ago and the host has not confirmed. '
              'Assume insulin is still running and reach them another way.',
          background: colors.dangerDeep,
          onBackground: colors.onDangerDeep,
        );
      }

      return _AlertPanel(
        icon: Icons.hourglass_top,
        heading: 'SUSPEND REQUESTED',
        body: 'Waiting for the host to confirm that insulin has stopped. It has '
            'not confirmed yet — assume insulin is still running.',
        background: colors.panel,
        onBackground: colors.ink,
        rule: colors.danger,
      );
    }

    final suspendedAt = snapshot!.suspendedAt ?? requestedAt;

    if (snapshot.suspendAcknowledged) {
      _syncTicker(running: false);
      final since = suspendedAt == null
          ? ''
          : ' since ${DateFormat.jm().format(suspendedAt)}';
      final duration = suspendedAt == null
          ? ''
          : ' · ${_describe(DateTime.now().difference(suspendedAt))}';
      return _AlertPanel(
        icon: Icons.check_circle,
        heading: 'INSULIN SUSPENDED · ACKNOWLEDGED',
        body: 'Someone on the host answered the alarm and chose to leave '
            'delivery stopped$since.$duration',
        background: colors.panel,
        onBackground: colors.ink,
        rule: colors.danger,
      );
    }

    // The worst state there is: insulin is off and nobody there has answered.
    _syncTicker(running: suspendedAt != null);
    return _UnansweredPanel(suspendedAt: suspendedAt);
  }

  static String _describe(Duration duration) {
    if (duration.inMinutes < 1) return 'just now';
    if (duration.inMinutes < 60) return '${duration.inMinutes} min';
    return '${duration.inHours} h ${duration.inMinutes % 60} min';
  }
}

/// Insulin is stopped and the alarm on the host is still ringing.
///
/// Gets the whole top of the screen and a clock that counts, because the only
/// useful thing this app can offer at this point is not another number but a
/// way to reach whoever is holding that phone.
class _UnansweredPanel extends StatelessWidget {
  const _UnansweredPanel({required this.suspendedAt});

  final DateTime? suspendedAt;

  /// The elapsed clock: minutes and seconds while it is still minutes, hours
  /// and minutes once it stops being.
  static String _elapsed(Duration duration) {
    final seconds = duration.inSeconds.clamp(0, 1 << 30);
    if (seconds < 3600) {
      return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
    }
    return '${seconds ~/ 3600}:${((seconds % 3600) ~/ 60).toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final at = suspendedAt;

    return TrioPanel(
      color: colors.dangerDeep,
      padding: const EdgeInsets.fromLTRB(TrioMetrics.inset, 14, TrioMetrics.inset, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.pan_tool, size: 16, color: colors.onDangerDeep),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'INSULIN SUSPENDED · NOT ANSWERED',
                  style: TrioType.micro(color: colors.onDangerDeep, size: 10.5),
                ),
              ),
            ],
          ),
          if (at != null) ...[
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Semantics(
                  label: 'Insulin has been suspended for '
                      '${DateTime.now().difference(at).inMinutes} minutes',
                  excludeSemantics: true,
                  child: Text(
                    _elapsed(DateTime.now().difference(at)),
                    style: TrioType.numeral(
                      size: 46,
                      color: colors.onDangerDeep,
                      tracking: -0.04,
                      height: 0.9,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text(
                    'SINCE ${DateFormat.jm().format(at).toUpperCase()}',
                    style: TrioType.micro(
                      color: colors.onDangerDeep.withValues(alpha: 0.75),
                      size: 10,
                      weight: FontWeight.w500,
                      tracking: 0.14,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Text(
            'Nobody on the host has answered the alarm. Nothing restarts '
            'insulin on its own — reach them another way.',
            style: TrioType.body(
              color: colors.onDangerDeep.withValues(alpha: 0.92),
              size: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: _ReachOutButton(
                  icon: Icons.call,
                  label: state.hostContact == null ? 'Add a number' : 'Call',
                  filled: true,
                  onTap: () => _reach(context, sms: false),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 112,
                child: _ReachOutButton(
                  label: 'Message',
                  filled: false,
                  onTap: () => _reach(context, sms: true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Calls or texts the number the follower saved, asking for one the first
  /// time. The host never sends a phone number — pairing carries push
  /// addresses and secrets — so this device is the only place it can come
  /// from, and the alarm is exactly the wrong moment to go hunting for it.
  Future<void> _reach(BuildContext context, {required bool sms}) async {
    final state = context.read<AppState>();
    var number = state.hostContact;
    if (number == null) {
      number = await _askForNumber(context);
      if (number == null) return;
      await state.setHostContact(number);
    }
    final uri = Uri(scheme: sms ? 'sms' : 'tel', path: number);
    if (!await launchUrl(uri)) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('This device cannot ${sms ? 'send messages' : 'place calls'}.')),
      );
    }
  }

  Future<String?> _askForNumber(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        final colors = TrioTheme.of(dialogContext);
        return AlertDialog(
          title: Text('Number to call', style: TrioType.title(color: colors.ink, size: 17)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Kept on this device only. The host does not send one.',
                style: TrioType.body(color: colors.inkMuted, size: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.phone,
                style: TrioType.numeral(size: 16, color: colors.ink),
                decoration: const InputDecoration(border: OutlineInputBorder()),
                onSubmitted: (value) => Navigator.of(dialogContext).pop(value.trim()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                Navigator.of(dialogContext).pop(value.isEmpty ? null : value);
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }
}

class _ReachOutButton extends StatelessWidget {
  const _ReachOutButton({
    this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  final IconData? icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final ink = filled ? colors.dangerDeep : colors.onDangerDeep;

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: filled ? colors.onDangerDeep : Colors.transparent,
            border: filled
                ? null
                : Border.all(color: colors.onDangerDeep.withValues(alpha: 0.55), width: 1.5),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 17, color: ink),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  overflow: TextOverflow.ellipsis,
                  style: TrioType.micro(color: ink, size: 11, tracking: 0.13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quieter suspension states: requested, refused, unanswered by the push,
/// or acknowledged on the host.
class _AlertPanel extends StatelessWidget {
  const _AlertPanel({
    required this.icon,
    required this.heading,
    required this.body,
    required this.background,
    required this.onBackground,
    this.rule,
  });

  final IconData icon;
  final String heading;
  final String body;
  final Color background;
  final Color onBackground;

  /// A left-hand rule, for the states drawn on a plain panel rather than in
  /// full danger red — it is what keeps them from reading as ordinary content.
  final Color? rule;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return TrioPanel(
      color: background,
      padding: const EdgeInsets.fromLTRB(TrioMetrics.inset, 14, TrioMetrics.inset, 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rule != null) ...[
            TrioTick(color: rule!, height: 34),
            const SizedBox(width: 12),
          ] else ...[
            Icon(icon, size: 16, color: onBackground),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  heading,
                  style: TrioType.micro(
                    color: rule ?? onBackground,
                    size: 10.5,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  body,
                  style: TrioType.body(
                    color: rule == null ? onBackground.withValues(alpha: 0.92) : colors.inkMuted,
                    size: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
