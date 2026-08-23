/// Structured AI food search result, JSON-compatible with the host's
/// `MealPhotoAnalysisResult` (Trio/Sources/Services/MealPhotoAI) — the same
/// schema the host enforces via structured outputs, so both apps review the
/// same estimate. Keep both sides in sync.
class FoodSearchResult {
  const FoodSearchResult({
    required this.isFood,
    required this.mealName,
    required this.components,
    required this.totalCarbsGrams,
    required this.totalFatGrams,
    required this.totalProteinGrams,
    required this.mealSource,
    required this.mealSourceRationale,
    required this.scaleReferenceNote,
    required this.absorptionHours,
    required this.absorptionRationale,
    required this.slowAbsorptionMeal,
    required this.overallConfidence,
    required this.warnings,
  });

  final bool isFood;
  final String mealName;
  final List<FoodComponent> components;
  final double totalCarbsGrams;
  final double totalFatGrams;
  final double totalProteinGrams;

  /// "homemade", "restaurant", "packaged" or "unknown".
  final String mealSource;
  final String mealSourceRationale;

  /// The portion assumptions the AI made (a text lookup has no photo to
  /// measure from).
  final String scaleReferenceNote;

  final double absorptionHours;
  final String absorptionRationale;
  final bool slowAbsorptionMeal;

  /// "low", "medium" or "high".
  final String overallConfidence;
  final List<String> warnings;

  static FoodSearchResult? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final components = <FoodComponent>[];
    final rawComponents = json['components'];
    if (rawComponents is List) {
      for (final entry in rawComponents) {
        final component = FoodComponent.fromJson(entry);
        if (component != null) components.add(component);
      }
    }
    return FoodSearchResult(
      isFood: json['isFood'] == true,
      mealName: (json['mealName'] as String?) ?? 'Meal',
      components: components,
      totalCarbsGrams: _grams(json['totalCarbsGrams']),
      totalFatGrams: _grams(json['totalFatGrams']),
      totalProteinGrams: _grams(json['totalProteinGrams']),
      mealSource: (json['mealSource'] as String?) ?? 'unknown',
      mealSourceRationale: (json['mealSourceRationale'] as String?) ?? '',
      scaleReferenceNote: (json['scaleReferenceNote'] as String?) ?? '',
      absorptionHours: _grams(json['absorptionHours']),
      absorptionRationale: (json['absorptionRationale'] as String?) ?? '',
      slowAbsorptionMeal: json['slowAbsorptionMeal'] == true,
      overallConfidence: (json['overallConfidence'] as String?) ?? 'low',
      warnings: json['warnings'] is List
          ? (json['warnings'] as List).whereType<String>().toList()
          : const [],
    );
  }

  static double _grams(Object? value) {
    if (value is! num) return 0;
    final grams = value.toDouble();
    return grams.isFinite && grams > 0 ? grams : 0;
  }
}

/// One separately orderable item of the meal, so quantities can be scaled
/// independently ("Chicken McNuggets (10 pc)" ×2).
class FoodComponent {
  const FoodComponent({
    required this.name,
    required this.portionEstimate,
    required this.carbsGrams,
    required this.fatGrams,
    required this.proteinGrams,
    required this.confidence,
  });

  final String name;
  final String portionEstimate;
  final double carbsGrams;
  final double fatGrams;
  final double proteinGrams;

  /// "low", "medium" or "high".
  final String confidence;

  static FoodComponent? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    return FoodComponent(
      name: name,
      portionEstimate: (json['portionEstimate'] as String?) ?? '',
      carbsGrams: FoodSearchResult._grams(json['carbsGrams']),
      fatGrams: FoodSearchResult._grams(json['fatGrams']),
      proteinGrams: FoodSearchResult._grams(json['proteinGrams']),
      confidence: (json['confidence'] as String?) ?? 'low',
    );
  }
}

/// What the user accepted after reviewing (and possibly re-scaling) a search
/// result — the values the meal screen sends to the host.
class AcceptedFoodEstimate {
  const AcceptedFoodEstimate({
    required this.mealName,
    required this.carbsGrams,
    required this.fatGrams,
    required this.proteinGrams,
    required this.absorptionHours,
  });

  final String mealName;
  final int carbsGrams;
  final int fatGrams;
  final int proteinGrams;

  /// Null when the meal absorbs normally and nothing needs spreading.
  final double? absorptionHours;
}
