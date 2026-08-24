import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../models/status_snapshot.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/confirm_command.dart';
import '../widgets/trio_controls.dart';

/// Starts or cancels an override preset.
///
/// Overrides must already exist on the host — the follower addresses them by
/// name and the host rejects names it does not know — so the only honest thing
/// to offer is the list the host itself reports. A host that does not report
/// one leaves nothing to pick from, and only then is a name asked for by hand.
class OverrideScreen extends StatefulWidget {
  const OverrideScreen({super.key});

  @override
  State<OverrideScreen> createState() => _OverrideScreenState();
}

class _OverrideScreenState extends State<OverrideScreen> {
  final _name = TextEditingController();
  String? _chosen;
  bool _sending = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(TrioCommand command, {required bool viaSheet}) async {
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
    final presets = state.snapshot?.overridePresets ?? const <OverridePreset>[];
    final active = state.snapshot?.override;
    final hostName = state.bundle?.hostName ?? 'the host';

    // A preset the host is already running is the one shown as chosen until
    // the follower picks another; without that the screen would claim nothing
    // is on when something is.
    final selected = _chosen ?? active?.name;
    final typed = _name.text.trim();
    final target = presets.isEmpty ? (typed.isEmpty ? null : typed) : selected;

    return TrioScreen(
      title: 'Override',
      action: Column(
        children: [
          TrioHoldButton(
            label: target == null ? 'Choose an override' : 'Hold to start $target',
            enabled: target != null && target != active?.name && !_sending,
            onCompleted: () => _run(TrioCommand.startOverride(target!), viaSheet: false),
          ),
          if (active != null) ...[
            const SizedBox(height: 8),
            TrioButton(
              label: 'Cancel ${active.name}',
              outlined: true,
              height: 44,
              background: colors.danger,
              onPressed: _sending
                  ? null
                  : () => _run(TrioCommand.cancelOverride(), viaSheet: true),
            ),
          ],
        ],
      ),
      child: TrioPanelList(
        children: [
          if (presets.isNotEmpty)
            TrioPanel(
              child: Column(
                children: [
                  TrioSectionHeader(label: 'Presets on $hostName'),
                  for (var index = 0; index < presets.length; index++)
                    _PresetRow(
                      preset: presets[index],
                      summary: _summarise(presets[index], mmol: mmol),
                      chosen: presets[index].name == selected,
                      divider: index != presets.length - 1,
                      onTap: () => setState(() => _chosen = presets[index].name),
                    ),
                ],
              ),
            )
          else
            TrioPanel(
              padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
              child: Column(
                children: [
                  const TrioSectionHeader(label: 'Override name'),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: TextField(
                      controller: _name,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      style: TrioType.label(color: colors.ink, size: 16),
                      inputFormatters: [LengthLimitingTextInputFormatter(64)],
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(
                          borderRadius: TrioMetrics.radius,
                        ),
                        hintText: 'Exactly as it is named on the host',
                        hintStyle: TrioType.body(color: colors.inkFaint, size: 14),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
          TrioNote(
            text: presets.isEmpty
                ? 'This host does not send its override presets, so the name has to '
                    'match one defined there exactly. Update the host to pick from a '
                    'list instead.'
                : 'Presets come from the host with every status push, so this list is '
                    'always what that phone actually has. Nothing here can invent one.',
          ),
        ],
      ),
    );
  }

  /// What a preset does, in the terms the host reports it.
  static String _summarise(OverridePreset preset, {required bool mmol}) {
    final parts = <String>[
      if (preset.percentage != null) '${preset.percentage!.round()}% BASAL',
      if (preset.targetMgdl != null)
        'TARGET ${mmol ? (preset.targetMgdl! / 18.0).toStringAsFixed(1) : preset.targetMgdl!.round()}',
      if (preset.durationMinutes != null)
        preset.durationMinutes! % 60 == 0
            ? '${preset.durationMinutes! ~/ 60} H'
            : '${preset.durationMinutes} M',
    ];
    return parts.isEmpty ? 'AS DEFINED ON THE HOST' : parts.join(' · ');
  }
}

class _PresetRow extends StatelessWidget {
  const _PresetRow({
    required this.preset,
    required this.summary,
    required this.chosen,
    required this.divider,
    required this.onTap,
  });

  final OverridePreset preset;
  final String summary;
  final bool chosen;
  final bool divider;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Semantics(
      button: true,
      selected: chosen,
      label: '${preset.name}, $summary',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 62,
          decoration: BoxDecoration(
            color: chosen ? colors.accentWash : null,
            border: divider
                ? Border(bottom: BorderSide(color: colors.hairlineSoft))
                : null,
          ),
          padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
          child: Row(
            children: [
              TrioTick(
                color: chosen ? colors.accent : colors.hairline,
                height: 24,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      preset.name,
                      overflow: TextOverflow.ellipsis,
                      style: TrioType.title(color: colors.ink, size: 16),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      summary,
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
              const SizedBox(width: 12),
              Icon(
                chosen ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                size: 20,
                color: chosen ? colors.accent : colors.rule,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
