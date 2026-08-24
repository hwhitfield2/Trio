import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/display_preferences.dart';
import '../models/glucose_ranges.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/glucose_colors.dart';
import '../widgets/trio_controls.dart';

/// Layout, colour and range for the Live Activity and the home screen widgets.
///
/// Unlike Trio's own version of this screen, these are stored on this device
/// and read by the widget extension directly — the host builds Live Activity
/// content when it pushes an update, and has no idea how this follower likes
/// to see it. Which is also why the preview sits at the top: nothing else on
/// this device shows the surface being configured.
class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final preferences = state.displayPreferences;
    // What the host currently reports, so the numbers here can be compared
    // with the ones they are overriding rather than guessed at.
    final hostRanges = state.snapshot?.glucoseRanges ?? GlucoseRanges.defaults;
    final mmol = state.units == 'mmol/L';

    String format(double mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    void update(DisplayPreferences updated) {
      context.read<AppState>().setDisplayPreferences(updated);
    }

    final following = preferences.followsHostRange;
    final low = preferences.glucoseLow ?? hostRanges.low;
    final high = preferences.glucoseHigh ?? hostRanges.high;

    return TrioScreen(
      title: 'Layout, colour & range',
      child: TrioPanelList(
        children: [
          const _LockScreenPreview(),
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Layout'),
                _SegmentedField<WidgetStyle>(
                  label: 'Lock Screen',
                  selected: preferences.lockScreenStyle,
                  segments: [
                    for (final style in WidgetStyle.values) (style, style.label),
                  ],
                  onChanged: (style) =>
                      update(preferences.copyWith(lockScreenStyle: style)),
                  divider: true,
                ),
                _SegmentedField<WidgetStyle>(
                  label: 'Watch & CarPlay',
                  caption: 'iOS 18+',
                  selected: preferences.watchStyle,
                  segments: [
                    for (final style in WidgetStyle.values) (style, style.label),
                  ],
                  onChanged: (style) => update(preferences.copyWith(watchStyle: style)),
                  divider: false,
                ),
              ],
            ),
          ),
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Colour'),
                _SegmentedField<GlucoseSchemeChoice>(
                  label: 'Scheme',
                  selected: preferences.glucoseScheme,
                  segments: [
                    for (final scheme in GlucoseSchemeChoice.values)
                      (scheme, scheme.label),
                  ],
                  onChanged: (scheme) =>
                      update(preferences.copyWith(glucoseScheme: scheme)),
                  divider: true,
                  footer: Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      children: [
                        Text(
                          'HOST REPORTS',
                          style: TrioType.micro(
                            color: colors.inkFaint,
                            size: 10,
                            weight: FontWeight.w400,
                            tracking: 0.1,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          hostRanges.isDynamic ? 'DYNAMIC' : 'STATIC',
                          style: TrioType.micro(
                            color: colors.ink,
                            size: 10,
                            tracking: 0.1,
                          ),
                        ),
                        const Spacer(),
                        // The three colours the chosen scheme would actually
                        // paint, at this host's own bounds: a legend that is
                        // read off the same code that draws the chart.
                        for (final sgv in [
                          hostRanges.low - 10,
                          (hostRanges.low + hostRanges.high) / 2,
                          hostRanges.high + 10,
                        ])
                          Padding(
                            padding: const EdgeInsets.only(left: 3),
                            child: Container(
                              width: 16,
                              height: 8,
                              color: glucoseColorFor(
                                sgv,
                                preferences.resolveRanges(hostRanges),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                _SegmentedField<GlucoseColorScheme>(
                  label: 'Widget glucose',
                  caption: preferences.glucoseColorScheme.label,
                  selected: preferences.glucoseColorScheme,
                  segments: [
                    for (final scheme in GlucoseColorScheme.values)
                      (scheme, scheme == GlucoseColorScheme.dynamicColor
                          ? 'By range'
                          : 'One colour'),
                  ],
                  onChanged: (scheme) =>
                      update(preferences.copyWith(glucoseColorScheme: scheme)),
                  divider: true,
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    TrioMetrics.inset,
                    14,
                    TrioMetrics.inset,
                    14,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  "Follow the host's range",
                                  style: TrioType.label(color: colors.ink),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  following
                                      ? '${format(hostRanges.low)} – ${format(hostRanges.high)} '
                                          '${state.units.toUpperCase()}, AS REPORTED'
                                      : 'OVERRIDDEN ON THIS DEVICE',
                                  style: TrioType.micro(
                                    color: colors.inkFaint,
                                    size: 10,
                                    weight: FontWeight.w400,
                                    tracking: 0.08,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 14),
                          TrioToggle(
                            value: following,
                            label: "Follow the host's range",
                            onChanged: (value) => update(
                              value
                                  ? preferences.copyWith(followHostRange: true)
                                  // Starting from the host's numbers rather
                                  // than from a guess: whoever turns this off
                                  // wants to adjust what they can see, not to
                                  // start over.
                                  : preferences.copyWith(
                                      glucoseLow: low,
                                      glucoseHigh: high,
                                      glucoseScheme: preferences.glucoseScheme,
                                    ),
                            ),
                          ),
                        ],
                      ),
                      if (!following) ...[
                        const SizedBox(height: 12),
                        _ThresholdRow(
                          label: 'Low',
                          display: format(low),
                          units: state.units,
                          onChanged: (delta) => update(
                            preferences.copyWith(
                              glucoseLow: (low + delta).clamp(
                                DisplayPreferences.thresholdFloor,
                                // Never at or above the high: a range that
                                // crosses itself would colour every reading at
                                // once.
                                high - 1,
                              ),
                            ),
                          ),
                        ),
                        _ThresholdRow(
                          label: 'High',
                          display: format(high),
                          units: state.units,
                          divider: false,
                          onChanged: (delta) => update(
                            preferences.copyWith(
                              glucoseHigh: (high + delta).clamp(
                                low + 1,
                                DisplayPreferences.thresholdCeiling,
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),
                      Text(
                        'Overriding it changes nothing on the host and nothing about '
                        'when you are alerted — it only decides what this device '
                        'calls trouble.',
                        style: TrioType.body(color: colors.inkMuted, size: 12.5),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Detailed layout · four slots'),
                for (var slot = 0; slot < DisplayPreferences.itemSlots; slot++)
                  _SlotRow(
                    slot: slot,
                    value: slot < preferences.items.length
                        ? preferences.items[slot]
                        : LiveActivityItem.empty,
                    divider: slot != DisplayPreferences.itemSlots - 1,
                    onChanged: (item) {
                      final items = [
                        for (var index = 0;
                            index < DisplayPreferences.itemSlots;
                            index++)
                          index < preferences.items.length
                              ? preferences.items[index]
                              : LiveActivityItem.empty,
                      ];
                      items[slot] = item;
                      update(preferences.copyWith(items: items));
                    },
                  ),
              ],
            ),
          ),
          const TrioNote(
            text: 'These four are what the detailed layouts show beneath the chart, '
                'left to right. The medium home screen widget follows them too.',
          ),
        ],
      ),
    );
  }
}

/// The Lock Screen as it would look, on the dark it would look it against.
class _LockScreenPreview extends StatelessWidget {
  const _LockScreenPreview();

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final snapshot = state.snapshot;
    final latest = snapshot?.latest;
    final mmol = state.units == 'mmol/L';

    String glucose(num mgdl) =>
        mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

    // Fallbacks so the preview is a preview even before the first push. Chosen
    // to be obviously in range, so nothing here reads as a live alarm.
    final value = latest == null ? glucose(142) : glucose(latest.sgv);
    final arrow = latest?.trendArrow ?? '→';
    final iob = snapshot?.iob?.toStringAsFixed(2) ?? '1.45';
    final cob = snapshot?.cob?.toStringAsFixed(0) ?? '18';
    final tint = glucoseColorFor(
      (latest?.sgv ?? 142).toDouble(),
      state.glucoseRanges,
    );

    return TrioPanel(
      color: const Color(0xFF16151A),
      padding: const EdgeInsets.all(TrioMetrics.inset),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'PREVIEW · LOCK SCREEN',
            style: TrioType.micro(color: const Color(0xFF86828E)),
          ),
          const SizedBox(height: 12),
          Container(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 5,
                      height: 5,
                      decoration: const BoxDecoration(
                        color: TrioColors.inRange,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'TRIO FOLLOWER · ${(state.bundle?.hostName ?? 'TRIO').toUpperCase()}',
                        overflow: TextOverflow.ellipsis,
                        style: TrioType.micro(
                          color: Colors.white.withValues(alpha: 0.7),
                          size: 8.5,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      value,
                      style: TrioType.numeral(
                        size: 42,
                        color: tint,
                        tracking: -0.05,
                        height: 0.86,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        arrow,
                        style: const TextStyle(
                          fontFamily: TrioType.sans,
                          fontSize: 19,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const Spacer(),
                    _PreviewStat(caption: 'IOB', value: iob),
                    const SizedBox(width: 14),
                    _PreviewStat(caption: 'COB', value: cob),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _PreviewStat extends StatelessWidget {
  const _PreviewStat({required this.caption, required this.value});

  final String caption;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              caption,
              style: TrioType.micro(
                color: Colors.white.withValues(alpha: 0.6),
                size: 8,
                weight: FontWeight.w400,
                tracking: 0.14,
              ),
            ),
            Text(value, style: TrioType.numeral(size: 13, color: Colors.white)),
          ],
        ),
      );
}

/// A named choice made with a segmented control.
class _SegmentedField<T> extends StatelessWidget {
  const _SegmentedField({
    required this.label,
    required this.selected,
    required this.segments,
    required this.onChanged,
    required this.divider,
    this.caption,
    this.footer,
  });

  final String label;
  final T selected;
  final List<(T, String)> segments;
  final ValueChanged<T> onChanged;
  final bool divider;
  final String? caption;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset, vertical: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: TrioType.label(color: colors.ink))),
              if (caption != null)
                Text(
                  caption!.toUpperCase(),
                  style: TrioType.micro(
                    color: colors.inkFaint,
                    size: 9.5,
                    weight: FontWeight.w400,
                    tracking: 0.1,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          TrioSegmented<T>(
            selected: selected,
            segments: segments,
            onChanged: onChanged,
          ),
          if (footer != null) footer!,
        ],
      ),
    );
  }
}

/// One end of this device's own glucose range.
class _ThresholdRow extends StatelessWidget {
  const _ThresholdRow({
    required this.label,
    required this.display,
    required this.units,
    required this.onChanged,
    this.divider = true,
  });

  final String label;
  final String display;
  final String units;

  /// Called with the change in mg/dL, which is what everything is stored in.
  final ValueChanged<double> onChanged;
  final bool divider;

  /// Whole mg/dL is finer than anyone needs; five is one step of the slider
  /// this replaced, and 0.3 mmol/L on a host that displays those.
  static const _step = 5.0;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: 48,
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      child: Row(
        children: [
          Expanded(child: Text(label, style: TrioType.label(color: colors.ink, size: 14))),
          Text(
            '$display ${units.toUpperCase()}',
            style: TrioType.numeral(size: 14, color: colors.ink),
          ),
          const SizedBox(width: 14),
          _NudgeButton(
            icon: Icons.remove,
            label: 'Lower the $label threshold',
            onPressed: () => onChanged(-_step),
          ),
          const SizedBox(width: 6),
          _NudgeButton(
            icon: Icons.add,
            label: 'Raise the $label threshold',
            onPressed: () => onChanged(_step),
          ),
        ],
      ),
    );
  }
}

class _NudgeButton extends StatelessWidget {
  const _NudgeButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Semantics(
      button: true,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(border: Border.all(color: colors.hairline)),
          child: Icon(icon, size: 17, color: colors.ink),
        ),
      ),
    );
  }
}

/// One of the four values a detailed layout shows beneath its chart.
class _SlotRow extends StatelessWidget {
  const _SlotRow({
    required this.slot,
    required this.value,
    required this.divider,
    required this.onChanged,
  });

  final int slot;
  final LiveActivityItem value;
  final bool divider;
  final ValueChanged<LiveActivityItem> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: TrioMetrics.rowHeight,
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            child: Text(
              '${slot + 1}',
              style: TrioType.numeral(
                size: 11,
                weight: FontWeight.w600,
                color: colors.inkFaint,
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: DropdownButtonHideUnderline(
              child: DropdownButton<LiveActivityItem>(
                value: value,
                isExpanded: true,
                isDense: true,
                borderRadius: TrioMetrics.radius,
                dropdownColor: colors.panel,
                icon: Icon(Icons.unfold_more, size: 20, color: colors.inkFaint),
                style: TrioType.label(color: colors.ink),
                items: [
                  for (final item in LiveActivityItem.values)
                    DropdownMenuItem(
                      value: item,
                      child: Text(item.label, style: TrioType.label(color: colors.ink)),
                    ),
                ],
                onChanged: (item) {
                  if (item != null) onChanged(item);
                },
              ),
            ),
          ),
        ],
      ),
    );
  }
}
