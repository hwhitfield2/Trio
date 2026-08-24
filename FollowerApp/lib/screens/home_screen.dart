import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/display_preferences.dart';
import '../models/status_snapshot.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/break_glass.dart';
import '../widgets/glucose_chart.dart';
import '../widgets/glucose_colors.dart';
import '../widgets/trio_controls.dart';
import 'action_sheet.dart';
import 'settings_screen.dart';

/// The whole point of the app: what the host's glucose is doing, what is
/// working on it, and one way in to change any of that.
///
/// Read top to bottom it answers the questions in the order a follower asks
/// them — is anything wrong, what is the number, where is it heading, what is
/// already on board, what has been given — with the controls last, out of the
/// way of the reading.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final suspended = snapshot?.suspended == true;

    return Scaffold(
      backgroundColor: colors.ground,
      body: Column(
        children: [
          // The suspension banner is drawn above the safe area's colour so a
          // stopped pump reaches all the way into the status bar. Nothing else
          // on this screen is allowed up there.
          ColoredBox(
            color: suspended && snapshot?.suspendAcknowledged != true
                ? colors.dangerDeep
                : colors.panel,
            child: const SafeArea(bottom: false, child: SizedBox(width: double.infinity)),
          ),
          const SuspensionBanner(),
          const _ConnectionStrip(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: state.requestStatus,
              color: colors.accent,
              backgroundColor: colors.panel,
              // Every panel is included only when it has something to draw:
              // TrioPanelList puts a gap of ground between whatever it is
              // given, so a panel that decides for itself to render nothing
              // still leaves its gap behind.
              child: TrioPanelList(
                children: [
                  if (state.updateAvailableVersion != null) const _UpdateNotice(),
                  if (state.liveActivityMissing) const _LiveActivityNotice(),
                  const _HeroPanel(),
                  if (snapshot?.latest != null) const _ChartPanel(),
                  if (snapshot?.tempTarget != null || snapshot?.override != null)
                    const _ActivePanel(),
                  if (snapshot != null && snapshot.treatments.isNotEmpty)
                    const _TreatmentLog(),
                  if (state.history.isNotEmpty) const _CommandLog(),
                ],
              ),
            ),
          ),
          TrioActionBar(
            child: Row(
              children: [
                Expanded(
                  child: TrioButton(
                    label: 'Send to host',
                    icon: Icons.send_to_mobile,
                    height: 52,
                    onPressed: () => showActionSheet(context),
                  ),
                ),
                const SizedBox(width: 10),
                const _SuspendKey(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The strip that says whether this screen can be believed: how long ago the
/// host was heard from, which host it is, and when its loop last ran.
class _ConnectionStrip extends StatelessWidget {
  const _ConnectionStrip();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final age = snapshot == null ? null : DateTime.now().difference(snapshot.timestamp);
    // Three missed pushes. Long enough not to cry wolf over one late delivery,
    // short enough that a phone that has genuinely gone quiet says so.
    final stale = age == null || age > const Duration(minutes: 15);

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: colors.panel,
        border: Border(bottom: BorderSide(color: colors.hairline)),
      ),
      padding: const EdgeInsets.only(left: TrioMetrics.inset, right: 6),
      child: Row(
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(
              color: stale ? colors.danger : TrioColors.inRange,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            age == null ? 'WAITING' : '${stale ? 'STALE' : 'LIVE'} · ${_short(age)}',
            style: TrioType.micro(
              color: stale ? colors.danger : colors.ink,
              size: 10.5,
              weight: FontWeight.w500,
              tracking: 0.13,
            ),
          ),
          const SizedBox(width: 10),
          Container(width: 1, height: 14, color: colors.hairline),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              state.bundle?.hostName ?? 'Trio',
              overflow: TextOverflow.ellipsis,
              style: TrioType.label(color: colors.inkMuted, size: 13),
            ),
          ),
          if (snapshot?.lastLoop != null) ...[
            const SizedBox(width: 8),
            Text(
              'LOOP ${_short(DateTime.now().difference(snapshot!.lastLoop!))}',
              style: TrioType.micro(
                color: colors.inkFaint,
                size: 10.5,
                weight: FontWeight.w400,
                tracking: 0.1,
              ),
            ),
          ],
          Semantics(
            button: true,
            label: 'Settings',
            child: InkWell(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SettingsScreen()),
              ),
              child: SizedBox(
                width: 34,
                height: 34,
                child: Icon(Icons.settings, size: 20, color: colors.inkMuted),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// An age in as few characters as the strip has room for.
  static String _short(Duration duration) {
    if (duration.inMinutes < 1) return 'NOW';
    if (duration.inMinutes < 60) return '${duration.inMinutes}M';
    if (duration.inHours < 24) return '${duration.inHours}H';
    return '${duration.inDays}D';
  }
}

/// The reading, and the three numbers that qualify it.
class _HeroPanel extends StatelessWidget {
  const _HeroPanel();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final latest = snapshot?.latest;
    final mmol = state.units == 'mmol/L';

    if (snapshot == null || latest == null) {
      return TrioPanel(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'WAITING FOR THE HOST',
              style: TrioType.micro(color: colors.inkFaint, size: 10.5),
            ),
            const SizedBox(height: 10),
            Text(
              'The host sends its status straight to this device. This keeps '
              'retrying by itself — pull down to ask right now.',
              style: TrioType.body(color: colors.inkMuted, size: 13.5),
            ),
            if (state.statusHint != null) ...[
              const SizedBox(height: 10),
              Text(
                state.statusHint!,
                style: TrioType.body(color: colors.danger, size: 12.5),
              ),
            ],
          ],
        ),
      );
    }

    String glucose(num mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    final delta = snapshot.delta;
    final deltaText = delta == null
        ? null
        : '${delta >= 0 ? '+' : '−'}'
            '${mmol ? (delta.abs() / 18.0).toStringAsFixed(1) : delta.abs()}';

    return TrioPanel(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: 'Glucose ${glucose(latest.sgv)} ${state.units}'
                '${deltaText == null ? '' : ', change $deltaText'}'
                ', at ${DateFormat.jm().format(latest.date)}',
            excludeSemantics: true,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // The reading and its trend are one group that takes whatever
                // the units and time do not need. Left flexible on its own:
                // sharing the row's slack with a Spacer would shrink a
                // three-digit reading to make room for empty space.
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.bottomLeft,
                          child: Text(
                            glucose(latest.sgv),
                            style: TrioType.numeral(
                              size: 84,
                              color: glucoseColorFor(
                                latest.sgv.toDouble(),
                                state.glucoseRanges,
                              ),
                              tracking: -0.045,
                              height: 0.86,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              latest.trendArrow,
                              style: TextStyle(
                                fontFamily: TrioType.sans,
                                fontSize: 30,
                                height: 1,
                                color: colors.ink,
                              ),
                            ),
                            if (deltaText != null)
                              Text(
                                deltaText,
                                style: TrioType.numeral(
                                  size: 17,
                                  color: colors.inkMuted,
                                  tracking: -0.01,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        state.units.toUpperCase(),
                        style: TrioType.micro(
                          color: colors.inkFaint,
                          size: 10,
                          weight: FontWeight.w500,
                          tracking: 0.14,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        DateFormat.jm().format(latest.date).toUpperCase(),
                        style: TrioType.numeral(size: 13, color: colors.ink),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: colors.hairline)),
            ),
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Stat(
                    caption: 'IOB',
                    value: snapshot.iob?.toStringAsFixed(2) ?? '—',
                    unit: snapshot.iob == null ? null : 'U',
                  ),
                  _StatDivider(color: colors.hairline),
                  _Stat(
                    caption: 'COB',
                    value: snapshot.cob?.toStringAsFixed(0) ?? '—',
                    unit: snapshot.cob == null ? null : 'G',
                    inset: true,
                  ),
                  _StatDivider(color: colors.hairline),
                  if (snapshot.suspended)
                    _Stat(
                      caption: 'PUMP',
                      value: 'STOP',
                      inset: true,
                      flex: 1.35,
                      color: colors.danger,
                    )
                  else
                    _Stat(
                      caption: 'EVENTUAL',
                      value: snapshot.eventualBg == null
                          ? '—'
                          : glucose(snapshot.eventualBg!),
                      inset: true,
                      flex: 1.35,
                    ),
                ],
              ),
            ),
          ),
          if (state.statusHint != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                state.statusHint!,
                style: TrioType.body(color: colors.danger, size: 12.5),
              ),
            ),
        ],
      ),
    );
  }
}

/// One of the three numbers under the reading.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.caption,
    required this.value,
    this.unit,
    this.inset = false,
    this.flex = 1,
    this.color,
  });

  final String caption;
  final String value;
  final String? unit;
  final bool inset;
  final double flex;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Expanded(
      flex: (flex * 100).round(),
      child: Semantics(
        label: '$caption $value ${unit ?? ''}',
        excludeSemantics: true,
        child: Padding(
          padding: EdgeInsets.fromLTRB(inset ? 14 : 0, 11, 0, 13),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                caption,
                style: TrioType.micro(
                  color: colors.inkFaint,
                  weight: FontWeight.w500,
                  tracking: 0.14,
                ),
              ),
              const SizedBox(height: 3),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.baseline,
                  textBaseline: TextBaseline.alphabetic,
                  children: [
                    Text(
                      value,
                      style: TrioType.numeral(
                        size: 19,
                        color: color ?? colors.ink,
                        tracking: -0.02,
                      ),
                    ),
                    if (unit != null)
                      Text(
                        ' $unit',
                        style: TrioType.numeral(size: 11, color: colors.inkFaint),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        color: color,
        margin: const EdgeInsets.fromLTRB(0, 11, 0, 13),
      );
}

/// The chart, with the span picker ruled across the top of its own panel.
class _ChartPanel extends StatelessWidget {
  const _ChartPanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;

    return TrioPanel(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        children: [
          TrioSegmented<int>(
            height: 38,
            bordered: false,
            selected: state.displayPreferences.chartHours,
            segments: [
              for (final hours in DisplayPreferences.chartHourChoices)
                (hours, '${hours}h'),
            ],
            onChanged: (hours) => context.read<AppState>().setChartHours(hours),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(TrioMetrics.inset, 10, TrioMetrics.inset, 0),
            // Drawn from the rolling history rather than the snapshot: a
            // snapshot only carries the last few hours, and the longer spans
            // show everything this device has collected.
            child: GlucoseChart(
              readings: state.readingHistory.readings,
              duration: state.chartDuration,
              units: state.units,
              ranges: state.glucoseRanges,
              treatments: state.readingHistory.treatments,
              suspendedAt: snapshot?.suspended == true ? snapshot?.suspendedAt : null,
            ),
          ),
        ],
      ),
    );
  }
}

/// What the host is running that this app can see — and, more to the point,
/// that a follower might otherwise send a second copy of.
class _ActivePanel extends StatelessWidget {
  const _ActivePanel();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final tempTarget = snapshot?.tempTarget;
    final activeOverride = snapshot?.override;

    final mmol = state.units == 'mmol/L';
    String glucose(num mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    return TrioPanel(
      child: Column(
        children: [
          const TrioSectionHeader(label: 'Active on host'),
          if (tempTarget != null)
            _ActiveRow(
              name: 'Temp target',
              value: glucose(tempTarget.target),
              until: tempTarget.until,
              divider: activeOverride != null,
            ),
          if (activeOverride != null)
            _ActiveRow(
              name: 'Override',
              value: activeOverride.name,
              until: activeOverride.until,
              divider: false,
            ),
        ],
      ),
    );
  }
}

class _ActiveRow extends StatelessWidget {
  const _ActiveRow({
    required this.name,
    required this.value,
    required this.until,
    required this.divider,
  });

  final String name;
  final String value;
  final DateTime? until;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: 46,
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
      child: Row(
        children: [
          TrioTick(color: colors.accent, height: 20),
          const SizedBox(width: 12),
          Expanded(child: Text(name, style: TrioType.label(color: colors.ink, size: 14))),
          Text(value, style: TrioType.numeral(size: 14, color: colors.ink)),
          if (until != null) ...[
            const SizedBox(width: 12),
            SizedBox(
              width: 78,
              child: Text(
                '→ ${DateFormat.jm().format(until!).toUpperCase()}',
                textAlign: TextAlign.right,
                style: TrioType.numeral(
                  size: 11,
                  weight: FontWeight.w400,
                  tracking: 0.06,
                  color: colors.inkFaint,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// What the pump gave and what was logged as eaten, newest first.
///
/// The chart's bars say when something happened; this says what, without
/// anyone having to hold a finger on one to find out.
class _TreatmentLog extends StatelessWidget {
  const _TreatmentLog();

  static const _shown = 6;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final treatments = state.snapshot?.treatments ?? const [];
    final newestFirst = treatments.reversed.take(_shown).toList();

    return TrioPanel(
      child: Column(
        children: [
          const TrioSectionHeader(label: 'Given & eaten'),
          for (var index = 0; index < newestFirst.length; index++)
            _TreatmentRow(
              treatment: newestFirst[index],
              divider: index != newestFirst.length - 1,
              colors: colors,
            ),
        ],
      ),
    );
  }
}

class _TreatmentRow extends StatelessWidget {
  const _TreatmentRow({
    required this.treatment,
    required this.divider,
    required this.colors,
  });

  final TreatmentEvent treatment;
  final bool divider;
  final TrioColors colors;

  @override
  Widget build(BuildContext context) {
    final isBolus = treatment is BolusEvent;
    final automatic = isBolus && (treatment as BolusEvent).isAutomatic;

    return Semantics(
      label: '${treatment.spokenLabel} at ${DateFormat.jm().format(treatment.date)}'
          '${automatic ? ', automatic' : ''}',
      excludeSemantics: true,
      child: Container(
        height: 36,
        decoration: divider
            ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
            : null,
        padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
        child: Row(
          children: [
            SizedBox(
              width: 62,
              child: Text(
                DateFormat.jm().format(treatment.date).toUpperCase(),
                style: TrioType.numeral(
                  size: 11,
                  weight: FontWeight.w400,
                  tracking: 0.02,
                  color: colors.inkFaint,
                ),
              ),
            ),
            const SizedBox(width: 12),
            TrioTick(color: isBolus ? TrioColors.insulin : TrioColors.carbs),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                isBolus ? 'Bolus' : 'Carbs',
                style: TrioType.label(color: colors.ink, size: 13.5),
              ),
            ),
            // A bolus the loop gave itself is not one anybody chose, and a
            // follower reading "3.5 U" deserves to know which it was.
            if (automatic) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: BoxDecoration(border: Border.all(color: colors.hairline)),
                child: Text(
                  'AUTO',
                  style: TrioType.micro(color: colors.inkFaint, size: 9, tracking: 0.12),
                ),
              ),
              const SizedBox(width: 10),
            ],
            SizedBox(
              width: 62,
              child: Text(
                treatment.label,
                textAlign: TextAlign.right,
                style: TrioType.numeral(size: 14, color: colors.ink),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// What this device has asked the host to do, and how that went.
///
/// Kept apart from "given & eaten" on purpose: that panel is what the pump
/// did, this one is what was sent from here, and a command that was accepted
/// for delivery is not yet a treatment.
class _CommandLog extends StatelessWidget {
  const _CommandLog();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final records = state.history.take(6).toList();

    return TrioPanel(
      child: Column(
        children: [
          const TrioSectionHeader(label: 'Sent from this device'),
          for (var index = 0; index < records.length; index++)
            Container(
              constraints: const BoxConstraints(minHeight: 44),
              decoration: index == records.length - 1
                  ? null
                  : BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.hairlineSoft)),
                    ),
              padding: const EdgeInsets.symmetric(
                horizontal: TrioMetrics.inset,
                vertical: 8,
              ),
              child: Row(
                children: [
                  TrioTick(
                    color: records[index].accepted ? TrioColors.inRange : colors.danger,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          records[index].description,
                          style: TrioType.label(color: colors.ink, size: 13.5),
                        ),
                        if (records[index].detail != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            records[index].detail!,
                            style: TrioType.body(color: colors.inkFaint, size: 11.5),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    DateFormat.jm().format(records[index].sentAt).toUpperCase(),
                    style: TrioType.numeral(
                      size: 11,
                      weight: FontWeight.w400,
                      color: colors.inkFaint,
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

/// The emergency stop, in a slot of its own beside the action button.
///
/// A different shape from everything else on the bar, permanently visible, and
/// never inside a menu: an insulin stop that has to be found is not one.
class _SuspendKey extends StatelessWidget {
  const _SuspendKey();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final stopped = state.snapshot?.suspended == true;

    return Semantics(
      button: true,
      label: stopped ? 'Insulin is stopped on the host' : 'Suspend all insulin',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: stopped ? null : () => confirmSuspend(context),
        child: Container(
          width: 74,
          height: 52,
          decoration: BoxDecoration(
            color: stopped ? colors.dangerDeep : Colors.transparent,
            border: stopped ? null : Border.all(color: colors.danger, width: 1.5),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.pan_tool,
                size: 17,
                color: stopped ? colors.onDangerDeep : colors.danger,
              ),
              const SizedBox(height: 3),
              Text(
                stopped ? 'STOPPED' : 'SUSPEND',
                style: TrioType.micro(
                  color: stopped ? colors.onDangerDeep : colors.danger,
                  size: 8.5,
                  tracking: 0.13,
                ),
              ),
            ],
          ),
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
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final version = state.updateAvailableVersion;
    if (version == null) return const SizedBox.shrink();

    return TrioPanel(
      child: TrioRow(
        label: 'Trio Follower $version is available',
        subtitle: 'The host reported a newer version',
        divider: false,
        leading: Icon(Icons.system_update, size: 20, color: colors.accent),
        trailing: Semantics(
          button: true,
          label: 'Dismiss',
          child: InkWell(
            onTap: () => context.read<AppState>().dismissUpdateNotice(),
            child: SizedBox(
              width: 40,
              height: 40,
              child: Icon(Icons.close, size: 18, color: colors.inkFaint),
            ),
          ),
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
    final colors = TrioTheme.of(context);

    return TrioPanel(
      child: TrioRow(
        label: 'Live Activity is not on the Lock Screen',
        subtitle: 'Dismissed, or the system ended it',
        divider: false,
        leading: Icon(Icons.dashboard_customize, size: 20, color: colors.accent),
        trailing: Semantics(
          button: true,
          label: 'Restart the Live Activity',
          child: InkWell(
            onTap: () => context.read<AppState>().restartLiveActivity(),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: Text(
                'RESTART',
                style: TrioType.micro(color: colors.accent, size: 10.5, tracking: 0.12),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
