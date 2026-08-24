import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/confirm_command.dart';
import '../widgets/trio_controls.dart';

/// A bolus, dialled rather than typed.
///
/// The old text field could be handed any number and only argued about it
/// afterwards. A stepper cannot leave the host's limit in the first place, and
/// it works one-handed, in the dark, without a keyboard covering the amount it
/// is about to send.
class BolusScreen extends StatefulWidget {
  const BolusScreen({super.key});

  @override
  State<BolusScreen> createState() => _BolusScreenState();
}

class _BolusScreenState extends State<BolusScreen> {
  /// Trio's own bolus increment. Anything finer is below what a pump delivers.
  static const _step = 0.05;
  static const _quickSet = [0.5, 1.0, 2.0, 5.0];

  double _units = 0;
  bool _sending = false;

  double get _maxBolus => context.read<AppState>().maxBolus;

  /// Kept to the pump's own increment: floating point arithmetic on repeated
  /// additions of 0.05 otherwise arrives at 1.2000000000000002, and that is
  /// what would be sent.
  void _setUnits(double value) {
    final clamped = value.clamp(0.0, _maxBolus);
    setState(() => _units = (clamped / _step).round() * _step);
  }

  Future<void> _send() async {
    if (_units <= 0 || _sending) return;
    setState(() => _sending = true);
    final sent = await authenticateAndSend(context, TrioCommand.bolus(_units));
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final iob = state.iobLabel;
    final max = state.maxBolus;
    final fraction = max <= 0 ? 0.0 : (_units / max).clamp(0.0, 1.0);

    return TrioScreen(
      title: 'Bolus',
      trailing: iob == null
          ? null
          : Text(
              'IOB $iob',
              style: TrioType.micro(
                color: colors.inkFaint,
                size: 10.5,
                weight: FontWeight.w400,
                tracking: 0.08,
              ),
            ),
      action: Column(
        children: [
          TrioHoldButton(
            label: 'Hold to send ${_units.toStringAsFixed(2)} U',
            enabled: _units > 0 && !_sending,
            onCompleted: _send,
          ),
          const TrioActionNote(text: 'Face ID confirms after the hold'),
        ],
      ),
      child: TrioPanelList(
        children: [
          TrioPanel(
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 20),
            child: Column(
              children: [
                Semantics(
                  label: '${_units.toStringAsFixed(2)} units',
                  excludeSemantics: true,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            _units.toStringAsFixed(2),
                            style: TrioType.numeral(
                              size: 78,
                              color: colors.ink,
                              tracking: -0.05,
                              height: 0.86,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'U',
                          style: TrioType.numeral(size: 20, color: colors.inkFaint),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                TrioStepper(
                  step: _step.toStringAsFixed(2),
                  semanticUnit: 'units',
                  onDecrement: _units <= 0 ? null : () => _setUnits(_units - _step),
                  onIncrement: _units >= max ? null : () => _setUnits(_units + _step),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    for (final quick in _quickSet) ...[
                      if (quick != _quickSet.first) const SizedBox(width: 8),
                      Expanded(
                        child: TrioQuickChip(
                          label: quick.toStringAsFixed(1),
                          onTap: quick > max ? null : () => _setUnits(quick),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
          TrioPanel(
            padding: const EdgeInsets.fromLTRB(
              TrioMetrics.inset,
              14,
              TrioMetrics.inset,
              16,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'AGAINST HOST LIMIT',
                      style: TrioType.micro(color: colors.inkFaint, tracking: 0.14),
                    ),
                    Text(
                      '${_units.toStringAsFixed(2)} / ${max.toStringAsFixed(1)} U',
                      style: TrioType.micro(color: colors.inkFaint, tracking: 0.14),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                // The limit as a distance rather than a sentence: how close
                // this is to the most the host will take, at a glance.
                SizedBox(
                  height: 6,
                  child: Stack(
                    children: [
                      Positioned.fill(child: ColoredBox(color: colors.ground)),
                      FractionallySizedBox(
                        alignment: Alignment.centerLeft,
                        widthFactor: fraction,
                        child: ColoredBox(color: colors.accent),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'The host re-checks max bolus, max IOB and recent boluses before '
                  'delivering, then pushes a new status — the result lands here in '
                  'seconds.',
                  style: TrioType.body(color: colors.inkMuted, size: 12.5),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
