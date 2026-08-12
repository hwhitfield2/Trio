import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final bundle = state.bundle;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: bundle == null
          ? const Center(child: Text('Not paired'))
          : ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.phone_iphone),
                  title: Text(bundle.hostName),
                  subtitle: const Text('Paired Trio host'),
                ),
                ListTile(
                  leading: const Icon(Icons.badge),
                  title: Text(bundle.followerName),
                  subtitle: const Text('This follower\'s name on the host'),
                ),
                ListTile(
                  leading: const Icon(Icons.verified_user),
                  title: Text(bundle.verificationCode),
                  subtitle: const Text('Pairing verification code'),
                ),
                if (state.liveActivitySupport.available)
                  SwitchListTile(
                    secondary: const Icon(Icons.dashboard_customize),
                    title: const Text('Live Activity'),
                    subtitle: Text(
                      state.liveActivitySupport.enabled
                          ? 'Glucose on the Lock Screen and in the Dynamic Island while the host keeps sending updates.'
                          : 'Turn Live Activities on for Trio Follower in iOS Settings to use this.',
                    ),
                    value: state.liveActivityEnabled,
                    // Left visible but disabled when the user switched Live
                    // Activities off for the app: hiding the row would leave no
                    // hint about where to turn them back on.
                    onChanged: state.liveActivitySupport.enabled
                        ? (value) => context.read<AppState>().setLiveActivityEnabled(value)
                        : null,
                  ),
                if (state.liveActivitySupport.available && state.liveActivityEnabled)
                  SwitchListTile(
                    secondary: const Icon(Icons.cloud_sync),
                    title: const Text('Let the host update it directly'),
                    subtitle: const Text(
                      'Keeps the Lock Screen current even while this app is '
                      'closed, instead of only when it runs. Apple has to read '
                      'these updates to draw them, so glucose, IOB and COB '
                      'travel as plain text — everything else this app '
                      'exchanges with the host stays encrypted either way.',
                    ),
                    value: state.liveActivityRemoteUpdates,
                    onChanged: state.liveActivitySupport.enabled
                        ? (value) => context.read<AppState>().setLiveActivityRemoteUpdates(value)
                        : null,
                  ),
                ListTile(
                  leading: const Icon(Icons.podcasts),
                  title: Text(
                    state.snapshot != null
                        ? 'Receiving encrypted status from the host'
                        : 'Waiting for the first status push from the host',
                  ),
                  subtitle: const Text('Data source: the Trio host device (no Nightscout)'),
                ),
                ListTile(
                  leading: const Icon(Icons.speed),
                  title: Text(
                    'Max bolus ${state.maxBolus.toStringAsFixed(1)} U · '
                    'Max carbs ${state.maxCarbs.toStringAsFixed(0)} g',
                  ),
                  subtitle: const Text('Limits received from the host'),
                ),
                ListTile(
                  leading: const Icon(Icons.notifications_active),
                  title: const Text('Re-register for status pushes'),
                  subtitle: const Text('Use this if the status stopped updating'),
                  onTap: () => state.registerPush(force: true),
                ),
                const Divider(),
                ListTile(
                  leading: Icon(Icons.link_off, color: Theme.of(context).colorScheme.error),
                  title: Text(
                    'Unpair from ${bundle.hostName}',
                    style: TextStyle(color: Theme.of(context).colorScheme.error),
                  ),
                  onTap: () async {
                    final confirmed = await showDialog<bool>(
                          context: context,
                          builder: (dialogContext) => AlertDialog(
                            title: const Text('Unpair?'),
                            content: const Text(
                              'This removes the pairing and all secrets from this '
                              'device. Also revoke this follower on the Trio host '
                              '(Settings → Remote Control) to fully disable it.',
                            ),
                            actions: [
                              TextButton(
                                onPressed: () => Navigator.of(dialogContext).pop(false),
                                child: const Text('Cancel'),
                              ),
                              FilledButton(
                                onPressed: () => Navigator.of(dialogContext).pop(true),
                                child: const Text('Unpair'),
                              ),
                            ],
                          ),
                        ) ??
                        false;
                    if (confirmed && context.mounted) {
                      await context.read<AppState>().unpair();
                      if (context.mounted) Navigator.of(context).pop();
                    }
                  },
                ),
              ],
            ),
    );
  }
}
