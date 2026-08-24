import 'package:flutter/material.dart';

import '../models/food_search_result.dart';
import '../models/pairing_bundle.dart';
import '../services/food_search_service.dart';
import '../theme/trio_design.dart';
import '../widgets/trio_controls.dart';

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
    return TrioScreen(
      title: _title,
      action: switch (_phase) {
        _Phase.input => TrioButton(
            label: 'Search',
            icon: Icons.search,
            onPressed: () {
              final trimmed = _query.text.trim();
              if (trimmed.isNotEmpty) _search(trimmed);
            },
          ),
        _Phase.searching => null,
        _Phase.result => TrioButton(
            label: 'Use these values',
            onPressed: _everythingExcluded ? null : _accept,
          ),
        _Phase.failed => TrioButton(
            label: 'Try again',
            onPressed: () => _search(_searchedQuery),
          ),
      },
      child: switch (_phase) {
        _Phase.input => _inputView(),
        _Phase.searching => _searchingView(),
        _Phase.result => _resultView(),
        _Phase.failed => _failedView(),
      },
    );
  }

  String get _title => switch (_phase) {
        _Phase.input => 'Food search',
        _Phase.searching => 'Searching',
        _Phase.result => 'Food estimate',
        _Phase.failed => 'Search failed',
      };

  Widget _inputView() {
    final colors = TrioTheme.of(context);
    return TrioPanelList(
      children: [
        TrioPanel(
          padding: const EdgeInsets.all(TrioMetrics.inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Describe what is being eaten. Include the restaurant name and '
                'portion details when you can.',
                style: TrioType.body(color: colors.inkMuted, size: 13),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _query,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                textInputAction: TextInputAction.search,
                style: TrioType.body(color: colors.ink, size: 14.5, height: 1.4),
                onSubmitted: (value) {
                  final trimmed = value.trim();
                  if (trimmed.isNotEmpty) _search(trimmed);
                },
                decoration: InputDecoration(
                  hintText: 'e.g. Chipotle chicken burrito bowl with white rice, '
                      'black beans, and cheese',
                  hintStyle: TrioType.body(color: colors.inkFaint, size: 14),
                  border: const OutlineInputBorder(borderRadius: TrioMetrics.radius),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _searchingView() {
    final colors = TrioTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              '“$_searchedQuery”',
              textAlign: TextAlign.center,
              style: TrioType.body(color: colors.ink, size: 14),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: 140,
              height: 2,
              child: LinearProgressIndicator(
                color: colors.accent,
                backgroundColor: colors.hairline,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              'LOOKING UP NUTRITION AND ESTIMATING CARBS',
              textAlign: TextAlign.center,
              style: TrioType.micro(color: colors.inkFaint, size: 10, tracking: 0.12),
            ),
          ],
        ),
      ),
    );
  }

  Widget _failedView() {
    final colors = TrioTheme.of(context);
    return TrioPanelList(
      children: [
        TrioPanel(
          padding: const EdgeInsets.all(TrioMetrics.inset),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TrioTick(color: colors.danger, height: 34),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SEARCH FAILED',
                      style: TrioType.micro(color: colors.danger, size: 10.5),
                    ),
                    const SizedBox(height: 6),
                    Text(_error, style: TrioType.body(color: colors.ink, size: 13.5)),
                  ],
                ),
              ),
            ],
          ),
        ),
        TrioPanel(
          child: TrioRow(
            label: 'Edit the search',
            labelColor: colors.accent,
            divider: false,
            trailing: const TrioChevron(),
            onTap: () => setState(() => _phase = _Phase.input),
          ),
        ),
      ],
    );
  }

  Widget _resultView() {
    final colors = TrioTheme.of(context);
    final result = _result!;

    return TrioPanelList(
      children: [
        TrioPanel(
          padding: const EdgeInsets.all(TrioMetrics.inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.mealName, style: TrioType.title(color: colors.ink, size: 20)),
              const SizedBox(height: 6),
              Text(
                'CONFIDENCE ${result.overallConfidence.toUpperCase()}',
                style: TrioType.micro(
                  color: colors.inkFaint,
                  size: 10,
                  weight: FontWeight.w400,
                  tracking: 0.1,
                ),
              ),
              if (result.scaleReferenceNote.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  result.scaleReferenceNote,
                  style: TrioType.body(color: colors.inkMuted, size: 12.5),
                ),
              ],
              if (result.mealSourceRationale.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  'Source: ${result.mealSource}. ${result.mealSourceRationale}',
                  style: TrioType.body(color: colors.inkMuted, size: 12.5),
                ),
              ],
            ],
          ),
        ),
        if (result.components.isNotEmpty)
          TrioPanel(
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Items'),
                for (var i = 0; i < result.components.length; i++)
                  _componentRow(i, result.components[i],
                      divider: i != result.components.length - 1),
              ],
            ),
          ),
        TrioPanel(
          padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
          child: Column(
            children: [
              const TrioSectionHeader(label: 'Totals'),
              _totalRow('Carbs', _adjustedCarbs, emphasise: true),
              _totalRow('Fat', _adjustedFat),
              _totalRow('Protein', _adjustedProtein, divider: false),
            ],
          ),
        ),
        TrioPanel(
          padding: const EdgeInsets.all(TrioMetrics.inset),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'CARB ABSORPTION',
                      style: TrioType.micro(color: colors.inkFaint, tracking: 0.14),
                    ),
                  ),
                  Text(
                    '${result.absorptionHours.toStringAsFixed(1)} H'
                    '${result.slowAbsorptionMeal ? ' · SLOW' : ''}',
                    style: TrioType.numeral(size: 13, color: colors.ink),
                  ),
                ],
              ),
              if (result.absorptionHours > _standardAbsorptionHours) ...[
                const SizedBox(height: 8),
                Text(
                  'When logged, the host spreads the carbs across this duration so '
                  'its dosing follows the slower absorption.',
                  style: TrioType.body(color: colors.inkMuted, size: 12.5),
                ),
              ],
              if (result.absorptionRationale.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  result.absorptionRationale,
                  style: TrioType.body(color: colors.inkMuted, size: 12.5),
                ),
              ],
            ],
          ),
        ),
        if (result.warnings.isNotEmpty)
          TrioPanel(
            padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Warnings'),
                for (final warning in result.warnings)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const TrioTick(color: TrioColors.high),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            warning,
                            style: TrioType.body(color: colors.ink, size: 13),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        TrioPanel(
          child: TrioRow(
            label: 'Edit the search',
            labelColor: colors.accent,
            divider: false,
            trailing: const TrioChevron(),
            onTap: () => setState(() => _phase = _Phase.input),
          ),
        ),
        const TrioNote(
          text: 'AI estimates can be wrong, and restaurant portions vary. Review '
              'the values before they are sent to the host.',
        ),
      ],
    );
  }

  Widget _componentRow(int index, FoodComponent component, {required bool divider}) {
    final colors = TrioTheme.of(context);
    final factor = _quantity(index);
    final excluded = factor == 0;
    final quantityLabel =
        '×${factor == factor.roundToDouble() ? factor.toStringAsFixed(0) : factor.toStringAsFixed(1)}';

    return Container(
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset, vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  component.name,
                  style: TrioType.label(
                    color: excluded ? colors.inkFaint : colors.ink,
                    size: 15,
                  ).copyWith(
                    decoration: excluded ? TextDecoration.lineThrough : null,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${(component.carbsGrams * factor).round()} g',
                style: TrioType.numeral(
                  size: 14,
                  color: excluded ? colors.inkFaint : TrioColors.carbs,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  component.portionEstimate,
                  style: TrioType.body(color: colors.inkFaint, size: 12),
                ),
              ),
              if (!excluded)
                Text(
                  'F ${(component.fatGrams * factor).round()} · '
                  'P ${(component.proteinGrams * factor).round()}',
                  style: TrioType.numeral(size: 11, color: colors.inkFaint),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                'QUANTITY',
                style: TrioType.micro(
                  color: colors.inkFaint,
                  size: 9.5,
                  weight: FontWeight.w400,
                  tracking: 0.12,
                ),
              ),
              const Spacer(),
              _QuantityButton(
                icon: Icons.remove,
                label: 'Less ${component.name}',
                onPressed: factor <= 0
                    ? null
                    : () => setState(() => _quantities[index] =
                        (factor - _quantityStep).clamp(0.0, _maxQuantity).toDouble()),
              ),
              SizedBox(
                width: 48,
                child: Text(
                  quantityLabel,
                  textAlign: TextAlign.center,
                  style: TrioType.numeral(size: 14, color: colors.ink),
                ),
              ),
              _QuantityButton(
                icon: Icons.add,
                label: 'More ${component.name}',
                onPressed: factor >= _maxQuantity
                    ? null
                    : () => setState(() => _quantities[index] =
                        (factor + _quantityStep).clamp(0.0, _maxQuantity).toDouble()),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _totalRow(String label, double grams, {bool emphasise = false, bool divider = true}) {
    final colors = TrioTheme.of(context);

    return Container(
      height: 44,
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TrioType.label(
                color: colors.ink,
                size: 14,
                weight: emphasise ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          Text(
            '${grams.round()} g',
            style: TrioType.numeral(
              size: emphasise ? 18 : 15,
              weight: emphasise ? FontWeight.w600 : FontWeight.w500,
              color: emphasise ? TrioColors.carbs : colors.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _QuantityButton extends StatelessWidget {
  const _QuantityButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final enabled = onPressed != null;

    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(border: Border.all(color: colors.hairline)),
            child: Icon(icon, size: 17, color: colors.ink),
          ),
        ),
      ),
    );
  }
}
