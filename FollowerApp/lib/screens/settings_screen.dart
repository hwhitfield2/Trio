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
