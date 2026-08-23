import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/display_preferences.dart';
import '../models/status_snapshot.dart';
import '../state/app_state.dart';
import '../widgets/break_glass.dart';
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
            // Above everything, including the reading: if insulin is stopped,
            // that is the most important thing on this screen.
            const SuspensionBanner(),
            if (state.snapshot?.suspended == true || state.suspendRequestedAt != null)
              const SizedBox(height: 12),
            if (state.updateAvailableVersion != null) ...[
              const _UpdateNotice(),
              const SizedBox(height: 12),
            ],
            const _LiveActivityNotice(),
            const _StatusCard(),
            const SizedBox(height: 16),
            Text('Remote actions', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            const _ActionGrid(),
            const SizedBox(height: 12),
            const BreakGlassButton(),
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

/// Offered when the Live Activity is switched on but is not on the Lock Screen.
///
/// A dismissed activity cannot be brought back from the Lock Screen itself, and
/// the system retires one every few hours on its own — so without somewhere to
/// say "put it back", the setting looks broken and the glucose that was meant
/// to be a glance away is simply gone.
class _LiveActivityNotice extends StatelessWidget {
  const _LiveActivityNotice();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    final missing = state.liveActivitySupport.available &&
        state.liveActivityEnabled &&
        !state.liveActivityRunning &&
        state.snapshot?.latest != null;
    if (!missing) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        color: theme.colorScheme.surfaceContainerHighest,
        child: ListTile(
          leading: const Icon(Icons.dashboard_customize),
          title: const Text('Live Activity is not on the Lock Screen'),
          subtitle: const Text(
            'It was dismissed, or the system ended it after a few hours.',
          ),
          trailing: TextButton(
            onPressed: () => context.read<AppState>().restartLiveActivity(),
            child: const Text('Restart'),
          ),
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
              const _ChartDurationPicker(),
              const SizedBox(height: 8),
              // Drawn from the rolling history rather than the snapshot: a
              // snapshot only carries the last few hours, and the longer spans
              // show everything this device has collected.
              GlucoseChart(
                readings: state.readingHistory.readings,
                duration: state.chartDuration,
                units: state.units,
                ranges: state.glucoseRanges,
                treatments: state.readingHistory.treatments,
              ),
              if (snapshot.treatments.isNotEmpty) ...[
                const SizedBox(height: 8),
                _TreatmentsRow(treatments: snapshot.treatments),
              ],
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

/// How far back the chart looks. The longer spans draw from the history this
/// device has collected, so right after installing they only reach as far as
/// the host has pushed since.
class _ChartDurationPicker extends StatelessWidget {
  const _ChartDurationPicker();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final theme = Theme.of(context);

    return SegmentedButton<int>(
      segments: [
        for (final hours in DisplayPreferences.chartHourChoices)
          ButtonSegment(value: hours, label: Text('${hours}h')),
      ],
      selected: {state.displayPreferences.chartHours},
      onSelectionChanged: (selection) => context.read<AppState>().setChartHours(selection.first),
      showSelectedIcon: false,
      // Five segments have to fit a phone-width card, so every point counts.
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 8)),
      ),
    );
  }
}

/// The last few boluses and carb entries, newest first.
///
/// The chart's markers say when something happened; this says what, without
/// anyone having to hold a finger on a triangle to find out. Only a handful:
/// this is a card on a home screen, not a history.
class _TreatmentsRow extends StatelessWidget {
  const _TreatmentsRow({required this.treatments});

  static const _shown = 4;

  final List<TreatmentEvent> treatments;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final newestFirst = treatments.reversed.take(_shown).toList();

    return Wrap(
      spacing: 8,
      runSpacing: 4,
      children: [
        for (final treatment in newestFirst)
          Semantics(
            label: '${treatment.spokenLabel} at ${DateFormat.jm().format(treatment.date)}',
            excludeSemantics: true,
            child: Chip(
              visualDensity: VisualDensity.compact,
              avatar: Icon(
                treatment is BolusEvent ? Icons.water_drop : Icons.restaurant,
                size: 16,
                color: treatment is BolusEvent ? const Color(0xFF1E96FC) : Colors.orange,
              ),
              label: Text(
                '${treatment.label} · ${DateFormat.jm().format(treatment.date)}'
                // A bolus the loop gave itself is not one anybody chose, and a
                // follower reading "3.5 U" deserves to know which it was.
                '${treatment is BolusEvent && treatment.isAutomatic ? ' · auto' : ''}',
                style: theme.textTheme.labelSmall,
              ),
            ),
          ),
      ],
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
