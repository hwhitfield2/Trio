import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../widgets/confirm_command.dart';

class TempTargetScreen extends StatefulWidget {
  const TempTargetScreen({super.key});

  @override
  State<TempTargetScreen> createState() => _TempTargetScreenState();
}

class _TempTargetScreenState extends State<TempTargetScreen> {
  // Temp targets travel in mg/dL; presets cover the common use cases.
  double _targetMgdl = 140;
  int _durationMinutes = 60;
  bool _sending = false;

  Future<void> _send(TrioCommand command) async {
    setState(() => _sending = true);
    final sent = await confirmAndSend(context, command);
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final mmol = context.read<AppState>().units == 'mmol/L';
    final displayTarget = mmol ? (_targetMgdl / 18.0).toStringAsFixed(1) : _targetMgdl.round().toString();
    final unitsLabel = mmol ? 'mmol/L' : 'mg/dL';

    return Scaffold(
      appBar: AppBar(title: const Text('Temp Target')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text('Target: $displayTarget $unitsLabel', style: theme.textTheme.titleMedium),
          Slider(
            value: _targetMgdl,
            min: 80,
            max: 200,
            divisions: (200 - 80) ~/ 5,
            label: '$displayTarget $unitsLabel',
            onChanged: (value) => setState(() => _targetMgdl = value),
          ),
          const SizedBox(height: 8),
          Text('Duration: $_durationMinutes min', style: theme.textTheme.titleMedium),
          Slider(
            value: _durationMinutes.toDouble(),
            min: 15,
            max: 240,
            divisions: (240 - 15) ~/ 15,
            label: '$_durationMinutes min',
            onChanged: (value) => setState(() => _durationMinutes = value.round()),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              ActionChip(
                label: const Text('Exercise (140, 2h)'),
                onPressed: () => setState(() {
                  _targetMgdl = 140;
                  _durationMinutes = 120;
                }),
              ),
              ActionChip(
                label: const Text('Pre-meal (80, 30m)'),
                onPressed: () => setState(() {
                  _targetMgdl = 80;
                  _durationMinutes = 30;
                }),
              ),
            ],
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _sending
                ? null
                : () => _send(TrioCommand.tempTarget(
                      targetMgdl: _targetMgdl.round(),
                      durationMinutes: _durationMinutes,
                    )),
            icon: const Icon(Icons.gps_fixed),
            label: Text(_sending ? 'Sending…' : 'Start temp target'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _sending ? null : () => _send(TrioCommand.cancelTempTarget()),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('Cancel active temp target'),
          ),
        ],
      ),
    );
  }
}
