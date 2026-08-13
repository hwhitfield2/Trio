import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/status_snapshot.dart';
import '../state/app_state.dart';
import '../widgets/glucose_chart.dart';
import 'bolus_screen.dart';
import 'meal_screen.dart';
import 'override_screen.dart';
import 'settings_screen.dart';
import 'temp_target_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final bundle = state.bundle!;

    return Scaffold(
      appBar: AppBar(
        title: Text(bundle.hostName),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SettingsScreen()),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: state.requestStatus,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.updateAvailableVersion != null) ...[
              const _UpdateNotice(),
              const SizedBox(height: 12),
            ],
            const _StatusCard(),
            const SizedBox(height: 16),
            Text('Remote actions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const _ActionGrid(),
            const SizedBox(height: 16),
            if (state.history.isNotEmpty) ...[
              Text('Recent commands', style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              ...state.history.take(10).map((record) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      record.accepted ? Icons.check_circle : Icons.error,
                      color: record.accepted ? Colors.green : theme.colorScheme.error,
                    ),
                    title: Text(record.description),
                    subtitle: Text(
                      '${DateFormat.yMMMd().add_jm().format(record.sentAt)}'
                      '${record.detail == null ? '' : ' · ${record.detail}'}',
                    ),
                  )),
            ],
          ],
        ),
      ),
    );
  }
}

/// Shown when the host has nudged this device about a newer follower build.
///
/// Deliberately just a message: the nudge arrives in the clear next to a
/// notification rather than through the encrypted command channel, so it tells
/// the user something and does nothing on its own.
class _UpdateNotice extends StatelessWidget {
  const _UpdateNotice();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final version = state.updateAvailableVersion;
    if (version == null) return const SizedBox.shrink();

    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: ListTile(
        leading: Icon(Icons.system_update, color: theme.colorScheme.onSecondaryContainer),
        title: Text(
          'Trio Follower $version is available',
          style: TextStyle(color: theme.colorScheme.onSecondaryContainer),
        ),
        subtitle: Text(
          'The host reported a newer version than the one on this device.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSecondaryContainer,
          ),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.close),
          color: theme.colorScheme.onSecondaryContainer,
          onPressed: () => context.read<AppState>().dismissUpdateNotice(),
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final snapshot = state.snapshot;
    final mmol = state.units == 'mmol/L';
    final latest = snapshot?.latest;

    String formatSgv(num sgv) => mmol ? (sgv / 18.0).toStringAsFixed(1) : sgv.round().toString();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (snapshot == null || latest == null) ...[
              const Text(
                'Waiting for data from the host, which sends its status '
                'directly to this device. This keeps retrying by itself — '
                'pull to refresh to ask right now.',
              ),
            ] else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    formatSgv(latest.sgv),
                    style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(latest.trendArrow, style: theme.textTheme.headlineMedium),
                  if (snapshot.delta != null) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${snapshot.delta! >= 0 ? '+' : ''}${mmol ? (snapshot.delta! / 18.0).toStringAsFixed(1) : snapshot.delta}',
                      style: theme.textTheme.titleMedium,
                    ),
                  ],
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(mmol ? 'mmol/L' : 'mg/dL', style: theme.textTheme.bodySmall),
                      Text(
                        DateFormat.jm().format(latest.date),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Wrap(
                spacing: 12,
                children: [
                  if (snapshot.iob != null)
                    Text('IOB ${snapshot.iob!.toStringAsFixed(2)} U', style: theme.textTheme.bodyMedium),
                  if (snapshot.cob != null)
                    Text('COB ${snapshot.cob!.toStringAsFixed(0)} g', style: theme.textTheme.bodyMedium),
                  if (snapshot.eventualBg != null)
                    Text('→ ${formatSgv(snapshot.eventualBg!)}', style: theme.textTheme.bodyMedium),
                ],
              ),
              if (snapshot.tempTarget != null || snapshot.override != null) ...[
                const SizedBox(height: 4),
                Wrap(
                  spacing: 8,
                  children: [
                    if (snapshot.tempTarget != null)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.gps_fixed, size: 16),
                        label: Text(
                          '${formatSgv(snapshot.tempTarget!.target)}'
                          '${snapshot.tempTarget!.until != null ? ' until ${DateFormat.jm().format(snapshot.tempTarget!.until!)}' : ''}',
                        ),
                      ),
                    if (snapshot.override != null)
                      Chip(
                        visualDensity: VisualDensity.compact,
                        avatar: const Icon(Icons.tune, size: 16),
                        label: Text(snapshot.override!.name),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              GlucoseChart(readings: snapshot.readings),
              const SizedBox(height: 8),
              _FreshnessRow(snapshot: snapshot),
            ],
            if (state.statusHint != null) ...[
              const SizedBox(height: 8),
              Text(
                state.statusHint!,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.tertiary),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _FreshnessRow extends StatelessWidget {
  const _FreshnessRow({required this.snapshot});

  final StatusSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final age = DateTime.now().difference(snapshot.timestamp);
    final stale = age > const Duration(minutes: 15);

    String describeAge(Duration duration) {
      if (duration.inMinutes < 1) return 'just now';
      if (duration.inMinutes < 60) return '${duration.inMinutes} min ago';
      return '${duration.inHours} h ago';
    }

    return Row(
      children: [
        Icon(
          stale ? Icons.cloud_off : Icons.phone_iphone,
          size: 14,
          color: stale ? theme.colorScheme.error : theme.colorScheme.outline,
        ),
        const SizedBox(width: 4),
        Text(
          'From host ${describeAge(age)}'
          '${snapshot.lastLoop != null ? ' · last loop ${describeAge(DateTime.now().difference(snapshot.lastLoop!))}' : ''}',
          style: theme.textTheme.bodySmall?.copyWith(
            color: stale ? theme.colorScheme.error : theme.colorScheme.outline,
          ),
        ),
      ],
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid();

  @override
  Widget build(BuildContext context) {
    final actions = [
      (
        Icons.water_drop,
        'Bolus',
        () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BolusScreen()))
      ),
      (
        Icons.restaurant,
        'Meal',
        () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MealScreen()))
      ),
      (
        Icons.gps_fixed,
        'Temp Target',
        () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const TempTargetScreen()))
      ),
      (
        Icons.tune,
        'Override',
        () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const OverrideScreen()))
      ),
    ];

    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.4,
      children: [
        for (final (icon, label, onTap) in actions)
          Card(
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: onTap,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Theme.of(context).colorScheme.primary),
                  const SizedBox(width: 8),
                  Text(label, style: Theme.of(context).textTheme.titleMedium),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
