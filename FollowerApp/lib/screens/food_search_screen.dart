import 'package:flutter/material.dart';

import '../models/food_search_result.dart';
import '../models/pairing_bundle.dart';
import '../services/food_search_service.dart';

/// Text-based AI food lookup, mirroring the host's Food Search: describe what
/// is being eaten, review the structured estimate, scale each item to what was
/// actually ordered, and accept. Pops with an [AcceptedFoodEstimate] the meal
/// screen turns into a remote meal command.
class FoodSearchScreen extends StatefulWidget {
  const FoodSearchScreen({super.key, required this.aiConfig});

  final AiConfig aiConfig;

  @override
  State<FoodSearchScreen> createState() => _FoodSearchScreenState();
}

enum _Phase { input, searching, result, failed }

class _FoodSearchScreenState extends State<FoodSearchScreen> {
  final _query = TextEditingController();
  late final FoodSearchService _service = FoodSearchService(widget.aiConfig);

  _Phase _phase = _Phase.input;
  String _searchedQuery = '';
  String _error = '';
  FoodSearchResult? _result;

  /// Quantity multiplier per component index. 0 = excluded.
  final Map<int, double> _quantities = {};

  /// The absorption threshold oref's own carb model already covers; only a
  /// meal slower than this is worth telling the host to spread
  /// (BaseCarbsStorage.standardAbsorptionHours on the host).
  static const _standardAbsorptionHours = 3.0;
  static const _quantityStep = 0.5;
  static const _maxQuantity = 10.0;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() {
      _phase = _Phase.searching;
      _searchedQuery = query;
    });
    try {
      final result = await _service.search(query);
      if (!mounted) return;
      setState(() {
        _result = result;
        _quantities.clear();
        _phase = _Phase.result;
      });
    } on FoodSearchException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.message;
        _phase = _Phase.failed;
      });
    }
  }

  // MARK: quantity adjustment (same model as the host's FoodSearchResultView)

  double _quantity(int index) => _quantities[index] ?? 1;

  double get _adjustedCarbs => _adjustedTotal((c) => c.carbsGrams, (r) => r.totalCarbsGrams);
  double get _adjustedFat => _adjustedTotal((c) => c.fatGrams, (r) => r.totalFatGrams);
  double get _adjustedProtein => _adjustedTotal((c) => c.proteinGrams, (r) => r.totalProteinGrams);

  double _adjustedTotal(
    double Function(FoodComponent) perComponent,
    double Function(FoodSearchResult) total,
  ) {
    final result = _result;
    if (result == null) return 0;
    if (result.components.isEmpty) return total(result);
    var sum = 0.0;
    for (var i = 0; i < result.components.length; i++) {
      sum += perComponent(result.components[i]) * _quantity(i);
    }
    return sum;
  }

  bool get _everythingExcluded {
    final result = _result;
    if (result == null || result.components.isEmpty) return false;
    for (var i = 0; i < result.components.length; i++) {
      if (_quantity(i) > 0) return false;
    }
    return true;
  }

  void _accept() {
    final result = _result;
    if (result == null) return;
    Navigator.of(context).pop(AcceptedFoodEstimate(
      mealName: result.mealName,
      carbsGrams: _adjustedCarbs.round(),
      fatGrams: _adjustedFat.round(),
      proteinGrams: _adjustedProtein.round(),
      absorptionHours:
          result.absorptionHours > _standardAbsorptionHours ? result.absorptionHours : null,
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_title)),
      body: switch (_phase) {
        _Phase.input => _inputView(),
        _Phase.searching => _searchingView(),
        _Phase.result => _resultView(),
        _Phase.failed => _failedView(),
      },
    );
  }

  String get _title => switch (_phase) {
        _Phase.input => 'Food Search',
        _Phase.searching => 'Searching',
        _Phase.result => 'Food Estimate',
        _Phase.failed => 'Search Failed',
      };

  Widget _inputView() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Describe what is being eaten. Include the restaurant name and portion '
          'details when you can.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _query,
          autofocus: true,
          minLines: 2,
          maxLines: 5,
          textInputAction: TextInputAction.search,
          onSubmitted: (value) {
            final trimmed = value.trim();
            if (trimmed.isNotEmpty) _search(trimmed);
          },
          decoration: const InputDecoration(
            hintText: 'e.g. Chipotle chicken burrito bowl with white rice, '
                'black beans, and cheese',
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () {
            final trimmed = _query.text.trim();
            if (trimmed.isNotEmpty) _search(trimmed);
          },
          icon: const Icon(Icons.search),
          label: const Text('Search'),
        ),
      ],
    );
  }

  Widget _searchingView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '“$_searchedQuery”',
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
            const SizedBox(height: 20),
            Text(
              'Looking up nutrition information and estimating carbs...',
              style: Theme.of(context).textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedView() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 40, color: Colors.orange.shade700),
            const SizedBox(height: 12),
            Text(_error, textAlign: TextAlign.center),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => _search(_searchedQuery),
              child: const Text('Try Again'),
            ),
            TextButton(
              onPressed: () => setState(() => _phase = _Phase.input),
              child: const Text('Edit Search'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resultView() {
    final result = _result!;
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(result.mealName, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text('Confidence: ${result.overallConfidence}', style: theme.textTheme.bodySmall),
        if (result.scaleReferenceNote.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(result.scaleReferenceNote, style: theme.textTheme.bodySmall),
        ],
        if (result.mealSourceRationale.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('Source: ${result.mealSource}. ${result.mealSourceRationale}',
              style: theme.textTheme.bodySmall),
        ],
        const Divider(height: 24),
        for (var i = 0; i < result.components.length; i++) _componentRow(i, result.components[i]),
        if (result.components.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 8),
            child: Text(
              'Adjust the quantity of each item to match what was ordered. '
              'Set an item to ×0 to leave it out.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        _totalRow('Total carbs', _adjustedCarbs, bold: true),
        _totalRow('Total fat', _adjustedFat),
        _totalRow('Total protein', _adjustedProtein),
        const Divider(height: 24),
        Text(
          'Carb absorption: about ${result.absorptionHours.toStringAsFixed(1)} h'
          '${result.slowAbsorptionMeal ? ' — slow-absorbing meal' : ''}',
          style: theme.textTheme.bodyMedium,
        ),
        if (result.absorptionHours > _standardAbsorptionHours)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'When logged, the host spreads the carbs across this duration so '
              'its dosing follows the slower absorption.',
              style: theme.textTheme.bodySmall,
            ),
          ),
        if (result.absorptionRationale.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(result.absorptionRationale, style: theme.textTheme.bodySmall),
          ),
        for (final warning in result.warnings)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange.shade700),
                const SizedBox(width: 6),
                Expanded(child: Text(warning, style: theme.textTheme.bodySmall)),
              ],
            ),
          ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: _everythingExcluded ? null : _accept,
          child: const Text('Use These Values'),
        ),
        TextButton(
          onPressed: () => setState(() => _phase = _Phase.input),
          child: const Text('Edit Search'),
        ),
        const SizedBox(height: 8),
        Text(
          'AI estimates can be wrong. Portions at restaurants vary - always '
          'review the values before they are sent to the host.',
          style: theme.textTheme.bodySmall,
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _componentRow(int index, FoodComponent component) {
    final theme = Theme.of(context);
    final factor = _quantity(index);
    final excluded = factor == 0;
    final quantityLabel =
        '×${factor == factor.roundToDouble() ? factor.toStringAsFixed(0) : factor.toStringAsFixed(1)}';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  component.name,
                  style: excluded
                      ? theme.textTheme.bodyLarge?.copyWith(
                          decoration: TextDecoration.lineThrough,
                          color: theme.disabledColor,
                        )
                      : theme.textTheme.bodyLarge,
                ),
              ),
              Text('${(component.carbsGrams * factor).round()} g carbs',
                  style: theme.textTheme.bodyMedium),
            ],
          ),
          Row(
            children: [
              Expanded(child: Text(component.portionEstimate, style: theme.textTheme.bodySmall)),
              if (!excluded)
                Text(
                  'Fat ${(component.fatGrams * factor).round()} g · '
                  'Protein ${(component.proteinGrams * factor).round()} g',
                  style: theme.textTheme.bodySmall,
                ),
            ],
          ),
          Row(
            children: [
              Text('Quantity', style: theme.textTheme.bodySmall),
              const Spacer(),
              IconButton(
                onPressed: factor <= 0
                    ? null
                    : () => setState(() => _quantities[index] =
                        (factor - _quantityStep).clamp(0.0, _maxQuantity).toDouble()),
                icon: const Icon(Icons.remove_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
              SizedBox(
                width: 44,
                child: Text(
                  quantityLabel,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall,
                ),
              ),
              IconButton(
                onPressed: factor >= _maxQuantity
                    ? null
                    : () => setState(() => _quantities[index] =
                        (factor + _quantityStep).clamp(0.0, _maxQuantity).toDouble()),
                icon: const Icon(Icons.add_circle_outline),
                visualDensity: VisualDensity.compact,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, double grams, {bool bold = false}) {
    final style = bold
        ? Theme.of(context).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.bold)
        : Theme.of(context).textTheme.bodyLarge;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(child: Text(label, style: style)),
          Text('${grams.round()} g', style: style),
        ],
      ),
    );
  }
}
