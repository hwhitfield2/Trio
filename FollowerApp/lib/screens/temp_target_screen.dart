import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../models/status_snapshot.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/confirm_command.dart';
import '../widgets/trio_controls.dart';

/// A temp target: a number and how long to hold it.
///
/// Both are dialled, and the presets the host defines are offered underneath —
/// but a target can always be set by hand, because unlike an override it is
/// just a value, and the host has nothing to recognise it by.
class TempTargetScreen extends StatefulWidget {
  const TempTargetScreen({super.key});

  @override
  State<TempTargetScreen> createState() => _TempTargetScreenState();
}

class _TempTargetScreenState extends State<TempTargetScreen> {
  /// Temp targets travel in mg/dL, whatever the host displays.
  static const _minTarget = 80.0;
  static const _maxTarget = 200.0;
  static const _targetStep = 5.0;
  static const _durationStep = 15;
  static const _minDuration = 15;
  static const _maxDuration = 240;

  double _targetMgdl = 140;
  int _durationMinutes = 60;
  bool _sending = false;

  void _apply(TempTargetPreset preset) {
    setState(() {
      _targetMgdl = preset.targetMgdl.clamp(_minTarget, _maxTarget);
      _durationMinutes = preset.durationMinutes.clamp(_minDuration, _maxDuration);
    });
  }

  Future<void> _send(TrioCommand command, {required bool viaSheet}) async {
    if (_sending) return;
    setState(() => _sending = true);
    final sent = viaSheet
        ? await confirmAndSend(context, command)
        : await authenticateAndSend(context, command);
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final mmol = state.units == 'mmol/L';
    final active = state.snapshot?.tempTarget;
    final presets = state.snapshot?.tempTargetPresets ?? const <TempTargetPreset>[];

    String glucose(num mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    return TrioScreen(
      title: 'Temp target',
      action: TrioHoldButton(
        label: active == null
            ? 'Hold to start · ${glucose(_targetMgdl)} / ${_durationMinutes}m'
            : 'Hold to replace · ${glucose(_targetMgdl)} / ${_durationMinutes}m',
        enabled: !_sending,
        onCompleted: () => _send(
          TrioCommand.tempTarget(
            targetMgdl: _targetMgdl.round(),
            durationMinutes: _durationMinutes,
          ),
          viaSheet: false,
        ),
      ),
      child: TrioPanelList(
        children: [
          if (active != null)
            _RunningBanner(
              summary: '${glucose(active.target)} ${state.units}'
                  '${active.until == null ? '' : ' → ${DateFormat.jm().format(active.until!).toUpperCase()}'}',
              onCancel: _sending
                  ? null
                  : () => _send(TrioCommand.cancelTempTarget(), viaSheet: true),
            ),
          TrioPanel(
            padding: const EdgeInsets.fromLTRB(20, 26, 20, 20),
            child: Column(
              children: [
                IntrinsicHeight(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: _Dial(
                          caption: 'Target',
                          value: glucose(_targetMgdl),
                          semantics: '${glucose(_targetMgdl)} ${state.units}',
                        ),
                      ),
                      Container(width: 1, height: 64, color: colors.hairline),
                      Expanded(
                        child: _Dial(
                          caption: 'For',
                          value: '$_durationMinutes',
                          suffix: 'm',
                          semantics: '$_durationMinutes minutes',
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    Expanded(
                      child: TrioStepper(
                        step: mmol
                            ? (_targetStep / 18.0).toStringAsFixed(1)
                            : _targetStep.toStringAsFixed(0),
                        height: 48,
                        semanticUnit: state.units,
                        onDecrement: _targetMgdl <= _minTarget
                            ? null
                            : () => setState(() => _targetMgdl -= _targetStep),
                        onIncrement: _targetMgdl >= _maxTarget
                            ? null
                            : () => setState(() => _targetMgdl += _targetStep),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TrioStepper(
                  step: '${_durationStep}m',
                  height: 48,
                  semanticUnit: 'minutes',
                  onDecrement: _durationMinutes <= _minDuration
                      ? null
                      : () => setState(() => _durationMinutes -= _durationStep),
                  onIncrement: _durationMinutes >= _maxDuration
                      ? null
                      : () => setState(() => _durationMinutes += _durationStep),
                ),
              ],
            ),
          ),
          if (presets.isNotEmpty)
            TrioPanel(
              padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
              child: Column(
                children: [
                  const TrioSectionHeader(label: 'Presets'),
                  for (var index = 0; index < presets.length; index++)
                    _PresetRow(
                      preset: presets[index],
                      summary: '${glucose(presets[index].targetMgdl)} · '
                          '${_duration(presets[index].durationMinutes)}',
                      divider: index != presets.length - 1,
                      onTap: () => _apply(presets[index]),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  static String _duration(int minutes) =>
      minutes % 60 == 0 ? '${minutes ~/ 60} H' : '$minutes M';
}

/// One of the two big numbers on this screen.
class _Dial extends StatelessWidget {
  const _Dial({
    required this.caption,
    required this.value,
    required this.semantics,
    this.suffix,
  });

  final String caption;
  final String value;
  final String semantics;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Semantics(
      label: '$caption $semantics',
      excludeSemantics: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            caption.toUpperCase(),
            style: TrioType.micro(color: colors.inkFaint, tracking: 0.14),
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  value,
                  style: TrioType.numeral(
                    size: 60,
                    color: colors.ink,
                    tracking: -0.05,
                    height: 0.9,
                  ),
                ),
                if (suffix != null)
                  Text(
                    suffix!,
                    style: TrioType.numeral(size: 20, color: colors.inkFaint),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The warning that something is already running, with the way to stop it.
///
/// Sending a second temp target replaces the first silently on the host, so
/// this is the only place a follower finds out there was one.
class _RunningBanner extends StatelessWidget {
  const _RunningBanner({required this.summary, required this.onCancel});

  final String summary;
  final VoidCallback? onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: colors.dangerWash,
        border: Border(bottom: BorderSide(color: colors.dangerWashLine)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset, vertical: 12),
      child: Row(
        children: [
          TrioTick(color: colors.danger, height: 26),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'ALREADY RUNNING',
                  style: TrioType.micro(color: colors.danger, tracking: 0.14),
                ),
                const SizedBox(height: 3),
                Text(summary, style: TrioType.numeral(size: 13, color: colors.ink)),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Semantics(
            button: true,
            label: 'Cancel the running temp target',
            excludeSemantics: true,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onCancel,
              child: Opacity(
                opacity: onCancel == null ? 0.45 : 1,
                child: Container(
                  height: 34,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(border: Border.all(color: colors.danger)),
                  child: Text(
                    'CANCEL',
                    style: TrioType.micro(color: colors.danger, size: 10.5, tracking: 0.1),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.preset,
    required this.summary,
    required this.divider,
    required this.onTap,
  });

  final TempTargetPreset preset;
  final String summary;
  final bool divider;
  final VoidCallback onTap;

  /// The host names its presets freely, so the icon is read off the name
  /// rather than sent. A guess that lands is worth a lot on a list scanned in
  /// a hurry; one that misses costs nothing, because the name is right there.
  IconData get _icon {
    final name = preset.name.toLowerCase();
    if (name.contains('exercis') || name.contains('run') || name.contains('sport') ||
        name.contains('walk') || name.contains('gym')) {
      return Icons.directions_run;
    }
    if (name.contains('meal') || name.contains('eat') || name.contains('food') ||
        name.contains('lunch') || name.contains('dinner')) {
      return Icons.restaurant_menu;
    }
    if (name.contains('night') || name.contains('sleep') || name.contains('bed')) {
      return Icons.bedtime;
    }
    return Icons.gps_fixed;
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Semantics(
      button: true,
      label: '${preset.name}, $summary',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 56,
          decoration: divider
              ? BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.hairlineSoft)),
                )
              : null,
          child: Row(
            children: [
              Icon(_icon, size: 20, color: colors.accent),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  preset.name,
                  overflow: TextOverflow.ellipsis,
                  style: TrioType.label(color: colors.ink, size: 15),
                ),
              ),
              Text(summary, style: TrioType.numeral(size: 13, color: colors.inkMuted)),
            ],
          ),
        ),
      ),
    );
  }
}
