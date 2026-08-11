import 'package:flutter/material.dart';

import '../models/command.dart';
import '../widgets/confirm_command.dart';

/// Starts or cancels an override preset. Overrides must already exist on the
/// host — the follower addresses them by name, and the host rejects names it
/// does not know.
class OverrideScreen extends StatefulWidget {
  const OverrideScreen({super.key});

  @override
  State<OverrideScreen> createState() => _OverrideScreenState();
}

class _OverrideScreenState extends State<OverrideScreen> {
  final _name = TextEditingController();
  bool _sending = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _run(TrioCommand command) async {
    setState(() => _sending = true);
    final sent = await confirmAndSend(context, command);
    if (mounted) {
      setState(() => _sending = false);
      if (sent) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Override')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          TextField(
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Override preset name',
              helperText: 'Must match an override preset defined on the Trio host.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Tip: keep override preset names short and distinctive on the host '
            '(for example "Sports" or "Sick day") so they are easy to enter here.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _sending
                ? null
                : () async {
                    final name = _name.text.trim();
                    if (name.isEmpty) return;
                    await _run(TrioCommand.startOverride(name));
                  },
            icon: const Icon(Icons.tune),
            label: Text(_sending ? 'Sending…' : 'Start override'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _sending ? null : () => _run(TrioCommand.cancelOverride()),
            icon: const Icon(Icons.cancel_outlined),
            label: const Text('Cancel active override'),
          ),
        ],
      ),
    );
  }
}
