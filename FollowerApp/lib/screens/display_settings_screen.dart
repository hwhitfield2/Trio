import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/display_preferences.dart';
import '../models/glucose_ranges.dart';
import '../state/app_state.dart';

/// Layout choices for the Live Activity and the home screen widgets, mirroring
/// Trio's own Live Activity settings.
///
/// Unlike Trio's, these are stored on this device and read by the widget
/// extension directly — the host builds Live Activity content when it pushes an
/// update, and has no idea how this follower likes to see it.
class DisplaySettingsScreen extends StatelessWidget {
  const DisplaySettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final preferences = state.displayPreferences;
    final theme = Theme.of(context);
    // What the host currently reports, so the numbers here can be compared
    // with the ones they are overriding rather than guessed at.
    final hostRanges = state.snapshot?.glucoseRanges ?? GlucoseRanges.defaults;

    void update(DisplayPreferences updated) {
      context.read<AppState>().setDisplayPreferences(updated);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Live Activity & widgets')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _StylePicker(
            title: 'Lock Screen style',
            value: preferences.lockScreenStyle,
            onChanged: (style) => update(preferences.copyWith(lockScreenStyle: style)),
          ),
          const Divider(),
          _StylePicker(
            title: 'Watch & CarPlay style',
            subtitle: 'How the Live Activity looks in the Apple Watch Smart Stack and on '
                'the CarPlay dashboard. Needs iOS 18 or later.',
            value: preferences.watchStyle,
            onChanged: (style) => update(preferences.copyWith(watchStyle: style)),
          ),
          const Divider(),
          _Choice<GlucoseColorScheme>(
            title: 'Glucose colour',
            values: GlucoseColorScheme.values,
            value: preferences.glucoseColorScheme,
            labelFor: (scheme) => scheme.label,
            descriptionFor: (scheme) => scheme.description,
            onChanged: (scheme) => update(preferences.copyWith(glucoseColorScheme: scheme)),
          ),
          const Divider(),
          _Choice<GlucoseSchemeChoice>(
            title: 'Colour scheme',
            subtitle: 'Which colouring to use. The host reports '
                '${hostRanges.isDynamic ? 'dynamic' : 'static'} with its latest '
                'status; this is where you disagree with it.',
            values: GlucoseSchemeChoice.values,
            value: preferences.glucoseScheme,
            labelFor: (scheme) => scheme.label,
            descriptionFor: (scheme) => scheme.description,
            onChanged: (scheme) => update(preferences.copyWith(glucoseScheme: scheme)),
          ),
          const Divider(),
          _RangePicker(
            preferences: preferences,
            hostRanges: hostRanges,
            units: state.units,
            onChanged: update,
          ),
          const Divider(),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text('Detailed layout', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Text(
              'The four values shown beneath the chart, left to right. Only the '
              'detailed styles above use them; the medium home screen widget '
              'follows them too.',
              style: theme.textTheme.bodySmall,
            ),
          ),
          for (var slot = 0; slot < DisplayPreferences.itemSlots; slot++)
            _ItemPicker(
              slot: slot,
              value: slot < preferences.items.length
                  ? preferences.items[slot]
                  : LiveActivityItem.empty,
              onChanged: (item) {
                final items = [
                  for (var index = 0; index < DisplayPreferences.itemSlots; index++)
                    index < preferences.items.length
                        ? preferences.items[index]
                        : LiveActivityItem.empty,
                ];
                items[slot] = item;
                update(preferences.copyWith(items: items));
              },
            ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// The range glucose is coloured against: the host's, or this device's own.
///
/// Two sliders rather than typed numbers: the value only has to be roughly
/// where the watcher wants it, and a keyboard over a dashboard is a poor
/// trade. Steps are whole mg/dL, which is 0.1 mmol/L to the nearest tenth.
class _RangePicker extends StatelessWidget {
  const _RangePicker({
    required this.preferences,
    required this.hostRanges,
    required this.units,
    required this.onChanged,
  });

  final DisplayPreferences preferences;

  /// What the host says, shown when following it and used as the starting
  /// point when someone stops.
  final GlucoseRanges hostRanges;
  final String units;
  final ValueChanged<DisplayPreferences> onChanged;

  bool get _mmol => units == 'mmol/L';

  String _format(double mgdl) =>
      _mmol ? (mgdl / 18.0).toStringAsFixed(1) : mgdl.round().toString();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final following = preferences.glucoseLow == null && preferences.glucoseHigh == null;
    final low = preferences.glucoseLow ?? hostRanges.low;
    final high = preferences.glucoseHigh ?? hostRanges.high;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Glucose range', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'The range everything on this device is coloured against — the chart, '
            'the widgets and the Lock Screen. It changes nothing on the host, and '
            'nothing about when you are alerted.',
            style: theme.textTheme.bodySmall,
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text("Use the host's range"),
            subtitle: Text(
              '${_format(hostRanges.low)} – ${_format(hostRanges.high)} $units, '
              'as the host reports it',
            ),
            value: following,
            onChanged: (value) => onChanged(
              value
                  ? preferences.copyWith(followHostRange: true)
                  // Starting from the host's numbers rather than from a guess:
                  // whoever turns this off wants to adjust what they can see,
                  // not to start over.
                  : preferences.copyWith(glucoseLow: low, glucoseHigh: high),
            ),
          ),
          if (!following) ...[
            _ThresholdSlider(
              label: 'Low',
              value: low,
              min: DisplayPreferences.thresholdFloor,
              // Never above the high: a range that crosses itself would colour
              // every reading at once.
              max: high - 1,
              format: _format,
              units: units,
              onChanged: (value) => onChanged(preferences.copyWith(glucoseLow: value)),
            ),
            _ThresholdSlider(
              label: 'High',
              value: high,
              min: low + 1,
              max: DisplayPreferences.thresholdCeiling,
              format: _format,
              units: units,
              onChanged: (value) => onChanged(preferences.copyWith(glucoseHigh: value)),
            ),
          ],
        ],
      ),
    );
  }
}

class _ThresholdSlider extends StatelessWidget {
  const _ThresholdSlider({
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.format,
    required this.units,
    required this.onChanged,
  });

  final String label;
  final double value;
  final double min;
  final double max;
  final String Function(double) format;
  final String units;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // A value already outside its bounds — a range narrowed from the other end
    // — would assert inside Slider rather than simply draw at the edge.
    final clamped = value.clamp(min, max).toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: theme.textTheme.bodyMedium),
            Text('${format(clamped)} $units', style: theme.textTheme.titleSmall),
          ],
        ),
        Slider(
          value: clamped,
          min: min,
          max: max,
          divisions: (max - min).round().clamp(1, 400),
          label: format(clamped),
          onChanged: (selected) => onChanged(selected.roundToDouble()),
        ),
      ],
    );
  }
}

class _StylePicker extends StatelessWidget {
  const _StylePicker({
    required this.title,
    required this.value,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final WidgetStyle value;
  final ValueChanged<WidgetStyle> onChanged;

  @override
  Widget build(BuildContext context) => _Choice<WidgetStyle>(
        title: title,
        subtitle: subtitle,
        values: WidgetStyle.values,
        value: value,
        labelFor: (style) => style.label,
        descriptionFor: (style) => style.description,
        onChanged: onChanged,
      );
}

/// A titled row of mutually exclusive options, with the chosen one explained
/// underneath.
///
/// A segmented control rather than a list of radios: the replacement for the
/// deprecated `RadioListTile` API needs a newer Flutter than this app declares
/// support for, and two options read better side by side anyway.
class _Choice<T> extends StatelessWidget {
  const _Choice({
    required this.title,
    required this.values,
    required this.value,
    required this.labelFor,
    required this.descriptionFor,
    required this.onChanged,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<T> values;
  final T value;
  final String Function(T) labelFor;
  final String Function(T) descriptionFor;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: SegmentedButton<T>(
              segments: [
                for (final option in values)
                  ButtonSegment<T>(value: option, label: Text(labelFor(option))),
              ],
              selected: {value},
              showSelectedIcon: false,
              onSelectionChanged: (selection) {
                if (selection.isNotEmpty) onChanged(selection.first);
              },
            ),
          ),
          const SizedBox(height: 6),
          Text(descriptionFor(value), style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }
}

class _ItemPicker extends StatelessWidget {
  const _ItemPicker({
    required this.slot,
    required this.value,
    required this.onChanged,
  });

  final int slot;
  final LiveActivityItem value;
  final ValueChanged<LiveActivityItem> onChanged;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        radius: 14,
        child: Text('${slot + 1}', style: const TextStyle(fontSize: 13)),
      ),
      title: DropdownButton<LiveActivityItem>(
        value: value,
        isExpanded: true,
        underline: const SizedBox.shrink(),
        onChanged: (selected) {
          if (selected != null) onChanged(selected);
        },
        items: [
          for (final item in LiveActivityItem.values)
            DropdownMenuItem(value: item, child: Text(item.label)),
        ],
      ),
    );
  }
}
