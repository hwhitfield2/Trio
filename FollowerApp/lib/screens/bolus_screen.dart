import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/command.dart';
import '../widgets/confirm_command.dart';

class BolusScreen extends StatefulWidget {
  const BolusScreen({super.key, required this.maxBolus});

  final double maxBolus;

  @override
  State<BolusScreen> createState() => _BolusScreenState();
}

class _BolusScreenState extends State<BolusScreen> {
  final _controller = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final value = double.tryParse(_controller.text.replaceAll(',', '.'));
    if (value == null || value <= 0) {
      setState(() => _error = 'Enter a bolus amount in units.');
      return;
    }
    if (value > widget.maxBolus) {
      setState(() => _error =
          'The host allows at most ${widget.maxBolus.toStringAsFixed(1)} U per bolus.');
      return;
    }
    setState(() {
      _error = null;
      _sending = true;
    });
    final sent = await confirmAndSend(context, TrioCommand.bolus(value));
    if (mounted) {
      setState(() => _sending = false);
      if (sent) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Bolus')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
              ],
              decoration: InputDecoration(
                labelText: 'Bolus amount (U)',
                helperText:
                    'Host limit: ${widget.maxBolus.toStringAsFixed(1)} U. The host re-checks '
                    'this and all other safety limits before delivering.',
                errorText: _error,
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _send(),
            ),
            const SizedBox(height: 16),
            Text(
              'The bolus is only delivered after Trio\'s own safety validation '
              '(max bolus, max IOB, recent boluses). You will see the result in '
              'Nightscout and on the host.',
              style: theme.textTheme.bodySmall,
            ),
            const Spacer(),
            FilledButton.icon(
              onPressed: _sending ? null : _send,
              icon: const Icon(Icons.water_drop),
              label: Text(_sending ? 'Sending…' : 'Send bolus'),
            ),
          ],
        ),
      ),
    );
  }
}
