import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../state/app_state.dart';
import '../widgets/confirm_command.dart';

class MealScreen extends StatefulWidget {
  const MealScreen({super.key});

  @override
  State<MealScreen> createState() => _MealScreenState();
}

class _MealScreenState extends State<MealScreen> {
  final _carbs = TextEditingController();
  final _fat = TextEditingController();
  final _protein = TextEditingController();
  final _bolus = TextEditingController();
  String? _error;
  bool _sending = false;

  @override
  void dispose() {
    _carbs.dispose();
    _fat.dispose();
    _protein.dispose();
    _bolus.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    final state = context.read<AppState>();
    final carbs = int.tryParse(_carbs.text);
    if (carbs == null || carbs <= 0) {
      setState(() => _error = 'Enter the carbs in grams.');
      return;
    }
    if (carbs > state.maxCarbs) {
      setState(() =>
          _error = 'The host allows at most ${state.maxCarbs.toStringAsFixed(0)} g of carbs.');
      return;
    }
    final fat = int.tryParse(_fat.text);
    final protein = int.tryParse(_protein.text);
    final bolus = double.tryParse(_bolus.text.replaceAll(',', '.'));
    if (bolus != null && bolus > state.maxBolus) {
      setState(() =>
          _error = 'The host allows at most ${state.maxBolus.toStringAsFixed(1)} U per bolus.');
      return;
    }

    setState(() {
      _error = null;
      _sending = true;
    });
    final sent = await confirmAndSend(
      context,
      TrioCommand.meal(carbs: carbs, fat: fat, protein: protein, bolusUnits: bolus),
    );
    if (mounted) {
      setState(() => _sending = false);
      if (sent) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Meal')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _numberField(_carbs, 'Carbs (g)', autofocus: true),
          const SizedBox(height: 12),
          _numberField(_fat, 'Fat (g, optional)'),
          const SizedBox(height: 12),
          _numberField(_protein, 'Protein (g, optional)'),
          const SizedBox(height: 12),
          _numberField(_bolus, 'Bolus with meal (U, optional)', decimal: true),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ],
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _sending ? null : _send,
            icon: const Icon(Icons.restaurant),
            label: Text(_sending ? 'Sending…' : 'Send meal'),
          ),
        ],
      ),
    );
  }

  Widget _numberField(
    TextEditingController controller,
    String label, {
    bool decimal = false,
    bool autofocus = false,
  }) {
    return TextField(
      controller: controller,
      autofocus: autofocus,
      keyboardType: TextInputType.numberWithOptions(decimal: decimal),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(decimal ? r'[0-9.,]' : r'[0-9]')),
      ],
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }
}
