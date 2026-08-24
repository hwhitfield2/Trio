import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/trio_controls.dart';
import 'display_settings_screen.dart';

/// Grouped panels with the values on the right, so the whole pairing can be
/// checked by running an eye down one column.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final bundle = state.bundle;

    if (bundle == null) {
      return const TrioScreen(
        title: 'Settings',
        child: Center(child: Text('Not paired')),
      );
    }

    final snapshot = state.snapshot;
    final age = snapshot == null ? null : DateTime.now().difference(snapshot.timestamp);

    return TrioScreen(
      title: 'Settings',
      child: TrioPanelList(
        children: [
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Pairing'),
                TrioRow(label: 'Host', value: bundle.hostName),
                TrioRow(label: 'This device is called', value: bundle.followerName),
                TrioRow(
                  label: 'Verification code',
                  valueWidget: Text(
                    // Spaced the way the host writes it, so the two are
                    // compared as the same shape rather than as six digits.
                    '${bundle.verificationCode.substring(0, 3)} '
                    '${bundle.verificationCode.substring(3)}',
                    style: TrioType.numeral(
                      size: 12.5,
                      color: colors.inkMuted,
                      tracking: 0.12,
                    ),
                  ),
                ),
                TrioRow(
                  label: 'Host limits',
                  value: '${state.maxBolus.toStringAsFixed(1)} U · '
                      '${state.maxCarbs.toStringAsFixed(0)} g',
                ),
                TrioRow(
                  label: 'Number to call',
                  subtitle: state.hostContact == null
                      ? 'Offered when insulin is stopped'
                      : 'On this device only',
                  value: state.hostContact ?? 'Not set',
                  divider: false,
                  trailing: const TrioChevron(),
                  onTap: () => _editContact(context, state),
                ),
              ],
            ),
          ),
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Connection'),
                TrioRow(
                  label: 'Encrypted status',
                  leading: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: snapshot == null ? colors.danger : TrioColors.inRange,
                      shape: BoxShape.circle,
                    ),
                  ),
                  value: snapshot == null
                      ? 'WAITING'
                      : 'RECEIVING · ${_short(age!)}',
                ),
                const TrioRow(label: 'Data source', value: 'HOST ONLY'),
                TrioRow(
                  label: 'Re-register for pushes',
                  labelColor: colors.accent,
                  divider: false,
                  trailing: Icon(Icons.refresh, size: 19, color: colors.accent),
                  onTap: () => state.registerPush(force: true),
                ),
              ],
            ),
          ),
          if (state.liveActivitySupport.available)
            TrioPanel(
              child: Column(
                children: [
                  const TrioSectionHeader(label: 'Lock Screen & widgets'),
                  TrioRow(
                    label: 'Live Activity',
                    height: 58,
                    subtitle: state.liveActivitySupport.enabled
                        ? (state.liveActivityRunning
                            ? 'Running · ${state.displayPreferences.lockScreenStyle.label} layout'
                            : 'Not on the Lock Screen')
                        : 'Turn Live Activities on in iOS Settings',
                    valueWidget: TrioToggle(
                      value: state.liveActivityEnabled,
                      label: 'Live Activity',
                      // Left visible but disabled when the user switched Live
                      // Activities off for the app: hiding the row would leave
                      // no hint about where to turn them back on.
                      onChanged: state.liveActivitySupport.enabled
                          ? (value) =>
                              context.read<AppState>().setLiveActivityEnabled(value)
                          : null,
                    ),
                  ),
                  if (state.liveActivityEnabled) ...[
                    TrioRow(
                      label: 'Host updates it directly',
                      height: 58,
                      subtitle: 'Sends glucose unencrypted',
                      valueWidget: TrioToggle(
                        value: state.liveActivityRemoteUpdates,
                        label: 'Host updates the Live Activity directly',
                        onChanged: state.liveActivitySupport.enabled
                            ? (value) => context
                                .read<AppState>()
                                .setLiveActivityRemoteUpdates(value)
                            : null,
                      ),
                    ),
                    TrioRow(
                      label: 'Start a new Live Activity',
                      subtitle: state.liveActivityRunning
                          ? 'Replaces the one on the Lock Screen'
                          : 'Puts it back',
                      trailing: Icon(Icons.restart_alt, size: 19, color: colors.accent),
                      labelColor: state.snapshot?.latest == null
                          ? colors.inkFaint
                          : colors.accent,
                      // Nothing to show until the host has sent a reading; the
                      // activity would be started and immediately ended again.
                      onTap: state.snapshot?.latest == null
                          ? null
                          : () => context.read<AppState>().restartLiveActivity(),
                    ),
                  ],
                  TrioRow(
                    label: 'Layout, colour & range',
                    divider: false,
                    trailing: const TrioChevron(),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const DisplaySettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
          TrioPanel(
            child: TrioRow(
              label: 'Unpair from ${bundle.hostName}',
              labelColor: colors.danger,
              height: 56,
              divider: false,
              leading: Icon(Icons.link_off, size: 20, color: colors.danger),
              onTap: () => _confirmUnpair(context),
            ),
          ),
        ],
      ),
    );
  }

  static String _short(Duration duration) {
    if (duration.inMinutes < 1) return 'NOW';
    if (duration.inMinutes < 60) return '${duration.inMinutes}M';
    if (duration.inHours < 24) return '${duration.inHours}H';
    return '${duration.inDays}D';
  }

  Future<void> _editContact(BuildContext context, AppState state) async {
    final colors = TrioTheme.of(context);
    final controller = TextEditingController(text: state.hostContact ?? '');
    final number = await showDialog<String?>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Number to call', style: TrioType.title(color: colors.ink, size: 17)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Offered on the alarm banner when insulin is stopped and nobody on '
              'the host has answered. Kept on this device; the host never sends one.',
              style: TrioType.body(color: colors.inkMuted, size: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              style: TrioType.numeral(size: 16, color: colors.ink),
              decoration: const InputDecoration(
                border: OutlineInputBorder(borderRadius: TrioMetrics.radius),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (number != null) await state.setHostContact(number);
  }

  Future<void> _confirmUnpair(BuildContext context) async {
    final colors = TrioTheme.of(context);
    final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Unpair?', style: TrioType.title(color: colors.ink, size: 17)),
            content: Text(
              'This removes the pairing and all secrets from this device. Also '
              'revoke this follower on the Trio host (Settings → Remote Control) '
              'to fully disable it.',
              style: TrioType.body(color: colors.inkMuted, size: 13.5),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                style: FilledButton.styleFrom(backgroundColor: colors.dangerDeep),
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('Unpair'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !context.mounted) return;
    await context.read<AppState>().unpair();
    if (context.mounted) Navigator.of(context).pop();
  }
}
