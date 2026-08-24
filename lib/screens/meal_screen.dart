import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/command.dart';
import '../models/food_search_result.dart';
import '../state/app_state.dart';
import '../theme/trio_design.dart';
import '../widgets/confirm_command.dart';
import '../widgets/trio_controls.dart';
import 'food_search_screen.dart';

/// Carbs first and large, everything else optional and small.
///
/// Carbs are the number the loop acts on and the only one that has to be
/// right; fat, protein and a bolus alongside are refinements, so they get
/// quiet rows rather than equal billing.
class MealScreen extends StatefulWidget {
  const MealScreen({super.key});

  @override
  State<MealScreen> createState() => _MealScreenState();
}

class _MealScreenState extends State<MealScreen> {
  static const _carbStep = 5;
  static const _macroStep = 5;
  static const _bolusStep = 0.05;

  int _carbs = 0;
  int _fat = 0;
  int _protein = 0;
  double _bolus = 0;
  bool _sending = false;

  /// Set when the numbers came from an accepted AI food search: the meal name
  /// and absorption estimate then travel with the command. Cleared as soon as
  /// the carbs are changed by hand — they are no longer what was estimated.
  AcceptedFoodEstimate? _fromSearch;

  Future<void> _searchFood() async {
    final aiConfig = context.read<AppState>().aiConfig;
    if (aiConfig == null) return;
    final accepted = await Navigator.of(context).push<AcceptedFoodEstimate>(
      MaterialPageRoute(builder: (_) => FoodSearchScreen(aiConfig: aiConfig)),
    );
    if (accepted == null || !mounted) return;
    setState(() {
      _fromSearch = accepted;
      _carbs = accepted.carbsGrams;
      _fat = accepted.fatGrams > 0 ? accepted.fatGrams : 0;
      _protein = accepted.proteinGrams > 0 ? accepted.proteinGrams : 0;
    });
  }

  void _setCarbs(int value) {
    final max = context.read<AppState>().maxCarbs.floor();
    setState(() {
      _carbs = value.clamp(0, max);
      // Hand-edited carbs are no longer the search's estimate; sending its
      // name and absorption along would misdescribe the entry.
      _fromSearch = null;
    });
  }

  Future<void> _send() async {
    if (_carbs <= 0 || _sending) return;
    setState(() => _sending = true);
    final search = _fromSearch;
    final sent = await authenticateAndSend(
      context,
      TrioCommand.meal(
        carbs: _carbs,
        fat: _fat > 0 ? _fat : null,
        protein: _protein > 0 ? _protein : null,
        bolusUnits: _bolus > 0 ? _bolus : null,
        note: search?.mealName,
        absorptionHours: search?.absorptionHours,
      ),
    );
    if (!mounted) return;
    setState(() => _sending = false);
    if (sent) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);
    final state = context.watch<AppState>();
    final cob = state.cobLabel;
    final search = _fromSearch;
    final maxCarbs = state.maxCarbs.floor();
    final maxBolus = state.maxBolus;

    return TrioScreen(
      title: 'Meal',
      trailing: cob == null
          ? null
          : Text(
              'COB ${cob.toUpperCase()}',
              style: TrioType.micro(
                color: colors.inkFaint,
                size: 10.5,
                weight: FontWeight.w400,
                tracking: 0.08,
              ),
            ),
      action: TrioHoldButton(
        label: 'Hold to send $_carbs g',
        enabled: _carbs > 0 && !_sending,
        onCompleted: _send,
      ),
      child: TrioPanelList(
        children: [
          if (state.aiConfig != null)
            TrioPanel(
              child: Semantics(
                button: true,
                label: 'Describe the food instead. Uses the host\'s AI food search.',
                excludeSemantics: true,
                child: InkWell(
                  onTap: _sending ? null : _searchFood,
                  child: Container(
                    height: 52,
                    padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
                    child: Row(
                      children: [
                        Icon(Icons.search, size: 20, color: colors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Describe the food instead',
                            style: TrioType.label(color: colors.accent, size: 14.5),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          decoration: BoxDecoration(
                            border: Border.all(color: colors.hairline),
                          ),
                          child: Text(
                            'AI',
                            style: TrioType.micro(
                              color: colors.inkFaint,
                              size: 9,
                              tracking: 0.12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (search != null)
            TrioPanel(
              padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
              child: Column(
                children: [
                  Container(
                    height: 44,
                    decoration: BoxDecoration(
                      border: Border(bottom: BorderSide(color: colors.hairlineSoft)),
                    ),
                    child: Row(
                      children: [
                        const TrioTick(color: TrioColors.carbs),
                        const SizedBox(width: 10),
                        Text(
                          'FROM SEARCH',
                          style: TrioType.micro(
                            color: colors.inkFaint,
                            size: 10.5,
                            weight: FontWeight.w400,
                            tracking: 0.1,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            search.mealName,
                            textAlign: TextAlign.right,
                            overflow: TextOverflow.ellipsis,
                            style: TrioType.label(color: colors.ink, size: 13),
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Detach the search result',
                          child: InkWell(
                            onTap: () => setState(() => _fromSearch = null),
                            child: SizedBox(
                              width: 34,
                              height: 44,
                              child: Icon(Icons.close, size: 17, color: colors.inkFaint),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (search.absorptionHours != null)
                    SizedBox(
                      height: 44,
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              'ABSORPTION',
                              style: TrioType.micro(
                                color: colors.inkFaint,
                                size: 10.5,
                                weight: FontWeight.w400,
                                tracking: 0.1,
                              ),
                            ),
                          ),
                          Text(
                            '${search.absorptionHours!.toStringAsFixed(1)} H ON HOST',
                            style: TrioType.numeral(size: 13, color: colors.ink),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          TrioPanel(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
            child: Column(
              children: [
                Semantics(
                  label: '$_carbs grams of carbs',
                  excludeSemantics: true,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Flexible(
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            '$_carbs',
                            style: TrioType.numeral(
                              size: 78,
                              color: TrioColors.carbs,
                              tracking: -0.05,
                              height: 0.86,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          'G CARBS',
                          style: TrioType.numeral(size: 20, color: colors.inkFaint),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 22),
                TrioStepper(
                  step: '$_carbStep',
                  height: 52,
                  semanticUnit: 'grams of carbs',
                  onDecrement: _carbs <= 0 ? null : () => _setCarbs(_carbs - _carbStep),
                  onIncrement:
                      _carbs >= maxCarbs ? null : () => _setCarbs(_carbs + _carbStep),
                ),
              ],
            ),
          ),
          TrioPanel(
            padding: const EdgeInsets.symmetric(horizontal: TrioMetrics.inset),
            child: Column(
              children: [
                const TrioSectionHeader(label: 'Optional'),
                _MacroRow(
                  label: 'Fat',
                  value: '$_fat g',
                  onDecrement: _fat <= 0
                      ? null
                      : () => setState(() => _fat = (_fat - _macroStep).clamp(0, 999)),
                  onIncrement: () => setState(() => _fat += _macroStep),
                ),
                _MacroRow(
                  label: 'Protein',
                  value: '$_protein g',
                  onDecrement: _protein <= 0
                      ? null
                      : () => setState(
                          () => _protein = (_protein - _macroStep).clamp(0, 999)),
                  onIncrement: () => setState(() => _protein += _macroStep),
                ),
                _MacroRow(
                  label: 'Bolus with it',
                  value: _bolus <= 0 ? '— U' : '${_bolus.toStringAsFixed(2)} U',
                  muted: _bolus <= 0,
                  divider: false,
                  onDecrement: _bolus <= 0
                      ? null
                      : () => setState(() {
                            final next = _bolus - _bolusStep;
                            _bolus = next < _bolusStep ? 0 : (next / _bolusStep).round() * _bolusStep;
                          }),
                  onIncrement: _bolus >= maxBolus
                      ? null
                      : () => setState(() {
                            final next = (_bolus + _bolusStep).clamp(0.0, maxBolus);
                            _bolus = (next / _bolusStep).round() * _bolusStep;
                          }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One optional value: a name, the amount, and a small pair of buttons.
class _MacroRow extends StatelessWidget {
  const _MacroRow({
    required this.label,
    required this.value,
    required this.onDecrement,
    required this.onIncrement,
    this.muted = false,
    this.divider = true,
  });

  final String label;
  final String value;
  final VoidCallback? onDecrement;
  final VoidCallback? onIncrement;
  final bool muted;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    final colors = TrioTheme.of(context);

    return Container(
      height: 48,
      decoration: divider
          ? BoxDecoration(border: Border(bottom: BorderSide(color: colors.hairlineSoft)))
          : null,
      child: Row(
        children: [
          Expanded(child: Text(label, style: TrioType.label(color: colors.ink, size: 14))),
          Text(
            value,
            style: TrioType.numeral(
              size: 15,
              color: muted ? colors.inkFaint : colors.ink,
            ),
          ),
          const SizedBox(width: 14),
          _MacroButton(icon: Icons.remove, onPressed: onDecrement, label: 'Less $label'),
          const SizedBox(width: 6),
          _MacroButton(icon: Icons.add, onPressed: onIncrement, label: 'More $label'),
        ],
      ),
    );
  }
}

class _MacroButton extends StatelessWidget {
  const _MacroButton({required this.icon, required this.onPressed, required this.label});

  final IconData icon;
  final VoidCallback? onPressed;
  final String label;

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
