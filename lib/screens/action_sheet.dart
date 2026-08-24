import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/break_glass.dart';
import '../widgets/trio_controls.dart';
import 'bolus_screen.dart';
import 'meal_screen.dart';
import 'override_screen.dart';
import 'temp_target_screen.dart';

/// What the sheet was asked for. The sheet only ever reports a choice: acting
/// on one means opening a screen or another sheet, and by then this one has
/// closed and its context is gone.
enum _Action { bolus, meal, tempTarget, override, suspend }

/// Everything this app can ask the host to do, in one sheet.
///
/// One entry point rather than a grid of tiles on the home screen: the home
/// screen's job is to be read, and four buttons competing with the reading is
/// how a follower ends up tapping one by accident. Each row carries the state
/// the host is actually in for that action, so the choice is made with the
/// numbers rather than before them.
Future<void> showActionSheet(BuildContext context) async {
  final chosen = await showModalBottomSheet<_Action>(
    context: context,
    isScrollControlled: true,
    backgroundColor: TrioTheme.of(context).panel,
    shape: const RoundedRectangleBorder(borderRadius: TrioMetrics.radius),
    builder: (sheetContext) => const _ActionSheet(),
  );
  if (chosen == null || !context.mounted) return;

  switch (chosen) {
    case _Action.bolus:
      await _push(context, const BolusScreen());
    case _Action.meal:
      await _push(context, const MealScreen());
    case _Action.tempTarget:
      await _push(context, const TempTargetScreen());
    case _Action.override:
      await _push(context, const OverrideScreen());
    case _Action.suspend:
      await confirmSuspend(context);
  }
}

Future<void> _push(BuildContext context, Widget screen) =>
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

class _ActionSheet extends StatelessWidget {
  const _ActionSheet();

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final mmol = state.units == 'mmol/L';

    String glucose(num mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    final iob = snapshot?.iob;
    final cob = snapshot?.cob;
    final tempTarget = snapshot?.tempTarget;
    final activeOverride = snapshot?.override;
    final presetCount = snapshot?.overridePresets.length ?? 0;

    return SafeArea(
      top: false,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 48,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.hairline)),
              ),
              padding: const EdgeInsets.only(left: TrioMetrics.inset, right: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'SEND TO ${(state.bundle?.hostName ?? 'THE HOST').toUpperCase()}',
                      overflow: TextOverflow.ellipsis,
                      style: TrioType.micro(color: colors.inkFaint, size: 10.5),
                    ),
                  ),
                  Semantics(
                    button: true,
                    label: 'Close',
                    child: InkWell(
                      onTap: () => Navigator.of(context).pop(),
                      child: SizedBox(
                        width: 44,
                        height: 44,
                        child: Icon(Icons.close, size: 20, color: colors.inkMuted),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            _ActionRow(
              icon: Icons.water_drop,
              title: 'Bolus',
              detail: [
                if (iob != null) 'IOB ${iob.toStringAsFixed(2)} U',
                'MAX ${state.maxBolus.toStringAsFixed(1)} U',
              ].join(' · '),
              onTap: () => Navigator.of(context).pop(_Action.bolus),
            ),
            _ActionRow(
              icon: Icons.restaurant,
              title: 'Meal',
              detail: [
                if (cob != null) 'COB ${cob.toStringAsFixed(0)} G',
                'MAX ${state.maxCarbs.toStringAsFixed(0)} G',
                if (state.aiConfig != null) 'AI SEARCH ON',
              ].join(' · '),
              onTap: () => Navigator.of(context).pop(_Action.meal),
            ),
            _ActionRow(
              icon: Icons.gps_fixed,
              title: 'Temp target',
              detail: tempTarget == null
                  ? 'NONE ACTIVE'
                  : 'ACTIVE · ${glucose(tempTarget.target)}'
                      '${tempTarget.until == null ? '' : ' → ${DateFormat.jm().format(tempTarget.until!).toUpperCase()}'}',
              onTap: () => Navigator.of(context).pop(_Action.tempTarget),
            ),
            _ActionRow(
              icon: Icons.tune,
              title: 'Override',
              detail: [
                if (activeOverride == null)
                  'NONE ACTIVE'
                else
                  'ACTIVE · ${activeOverride.name.toUpperCase()}',
                if (presetCount > 0)
                  '$presetCount PRESET${presetCount == 1 ? '' : 'S'} ON HOST',
              ].join(' · '),
              onTap: () => Navigator.of(context).pop(_Action.override),
            ),
            _ActionRow(
              icon: Icons.pan_tool,
              title: 'Suspend all insulin',
              detail: 'STOPS BASAL AND AUTOMATED DOSING',
              danger: true,
              divider: false,
              onTap: () => Navigator.of(context).pop(_Action.suspend),
            ),
            const SizedBox(height: 22),
          ],
        ),
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    required this.detail,
    required this.onTap,
    this.danger = false,
    this.divider = true,
  });

  final IconData icon;
  final String title;
  final String detail;
  final VoidCallback onTap;
  final bool danger;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final tint = danger ? colors.danger : colors.accent;

    return Semantics(
      button: true,
      label: '$title. $detail',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 68,
          decoration: divider
              ? BoxDecoration(
                  border: Border(bottom: BorderSide(color: colors.hairlineSoft)),
                )
              : null,
          padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
          child: Row(
            children: [
              Icon(icon, size: 22, color: tint),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TrioType.title(
                        color: danger ? colors.danger : colors.ink,
                        size: 16,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      detail,
                      overflow: TextOverflow.ellipsis,
                      style: TrioType.micro(
                        color: colors.inkFaint,
                        size: 10.5,
                        weight: FontWeight.w400,
                        tracking: 0.06,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              const TrioChevron(),
            ],
          ),
        ),
      ),
    );
  }
}
