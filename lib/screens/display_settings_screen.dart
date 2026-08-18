import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/display_preferences.dart';
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
