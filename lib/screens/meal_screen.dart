import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../models/food_search_result.dart';
import '../state/app_state.dart';
import '../widgets/confirm_command.dart';
import 'food_search_screen.dart';

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

  /// Set when the fields were filled from an accepted AI food search: the
  /// meal name and absorption estimate then travel with the command. Cleared
  /// as soon as the carbs are edited by hand — the numbers no longer are what
  /// the search estimated.
  AcceptedFoodEstimate? _fromSearch;

  @override
  void dispose() {
    _carbs.dispose();
    _fat.dispose();
    _protein.dispose();
    _bolus.dispose();
    super.dispose();
  }

  Future<void> _searchFood() async {
    final aiConfig = context.read<AppState>().aiConfig;
    if (aiConfig == null) return;
    final accepted = await Navigator.of(context).push<AcceptedFoodEstimate>(
      MaterialPageRoute(builder: (_) => FoodSearchScreen(aiConfig: aiConfig)),
    );
    if (accepted == null || !mounted) return;
    setState(() {
      _fromSearch = accepted;
      _carbs.text = accepted.carbsGrams.toString();
      _fat.text = accepted.fatGrams > 0 ? accepted.fatGrams.toString() : '';
      _protein.text = accepted.proteinGrams > 0 ? accepted.proteinGrams.toString() : '';
      _error = null;
    });
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
    final search = _fromSearch;
    final sent = await confirmAndSend(
      context,
      TrioCommand.meal(
        carbs: carbs,
        fat: fat,
        protein: protein,
        bolusUnits: bolus,
        note: search?.mealName,
        absorptionHours: search?.absorptionHours,
      ),
    );
    if (mounted) {
      setState(() => _sending = false);
      if (sent) Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final aiAvailable = context.watch<AppState>().aiConfig != null;
    final search = _fromSearch;
    return Scaffold(
      appBar: AppBar(title: const Text('Remote Meal')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (aiAvailable) ...[
            OutlinedButton.icon(
              onPressed: _sending ? null : _searchFood,
              icon: const Icon(Icons.search),
              label: const Text('Search food (AI)'),
            ),
            const SizedBox(height: 12),
          ],
          if (search != null) ...[
            _searchBanner(search),
            const SizedBox(height: 12),
          ],
          _numberField(_carbs, 'Carbs (g)', autofocus: !aiAvailable),
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

  /// Shows what the fields were filled from, so what gets sent is explicit —
  /// including that the host will spread a slow meal.
  Widget _searchBanner(AcceptedFoodEstimate search) {
    final theme = Theme.of(context);
    final absorption = search.absorptionHours;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              absorption == null
                  ? 'From food search: ${search.mealName}'
                  : 'From food search: ${search.mealName} · spread over '
                      '${absorption.toStringAsFixed(1)} h on the host',
              style: theme.textTheme.bodySmall,
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _fromSearch = null),
            icon: const Icon(Icons.close, size: 18),
            visualDensity: VisualDensity.compact,
            tooltip: 'Detach the search result',
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
      onChanged: identical(controller, _carbs)
          ? (_) {
              // Hand-edited carbs are no longer the search's estimate; sending
              // its name and absorption along would misdescribe the entry.
              if (_fromSearch != null) setState(() => _fromSearch = null);
            }
          : null,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
    );
  }
}
