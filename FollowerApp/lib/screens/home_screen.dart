import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

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
    final mmol = bundle.limits.units == 'mmol/L';

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
        onRefresh: state.refreshStatus,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (state.hasNightscout) _StatusCard(mmol: mmol) else const _NoNightscoutCard(),
            const SizedBox(height: 16),
            Text('Remote actions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            _ActionGrid(maxBolus: bundle.limits.maxBolus),
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

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.mmol});

  final bool mmol;

  String _formatSgv(int sgv) => mmol ? (sgv / 18.0).toStringAsFixed(1) : sgv.toString();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);
    final latest = state.entries.isEmpty ? null : state.entries.first;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.statusError != null)
              Text(state.statusError!, style: TextStyle(color: theme.colorScheme.error))
            else if (latest == null)
              const Text('No glucose data yet. Pull to refresh.')
            else ...[
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatSgv(latest.sgv),
                    style: theme.textTheme.displayMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(latest.trendArrow, style: theme.textTheme.headlineMedium),
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
              Row(
                children: [
                  if (state.status.iob != null)
                    Text('IOB ${state.status.iob!.toStringAsFixed(2)} U  ',
                        style: theme.textTheme.bodyMedium),
                  if (state.status.cob != null)
                    Text('COB ${state.status.cob!.toStringAsFixed(0)} g',
                        style: theme.textTheme.bodyMedium),
                ],
              ),
              const SizedBox(height: 12),
              GlucoseChart(entries: state.entries, mmol: mmol),
            ],
          ],
        ),
      ),
    );
  }
}

class _NoNightscoutCard extends StatelessWidget {
  const _NoNightscoutCard();

  @override
  Widget build(BuildContext context) {
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          'No Nightscout configured on the host, so live glucose is not '
          'available here. Remote commands still work.',
        ),
      ),
    );
  }
}

class _ActionGrid extends StatelessWidget {
  const _ActionGrid({required this.maxBolus});

  final double maxBolus;

  @override
  Widget build(BuildContext context) {
    final actions = [
      (
        Icons.water_drop,
        'Bolus',
        () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BolusScreen(maxBolus: maxBolus)),
            )
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
