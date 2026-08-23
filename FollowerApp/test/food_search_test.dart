import 'package:flutter_test/flutter_test.dart';
import 'package:trio_follower/models/food_search_result.dart';

void main() {
  group('FoodSearchResult', () {
    // The shape the host's structured-output schema guarantees
    // (BaseMealPhotoAnalysisManager.resultSchema).
    final sample = <String, dynamic>{
      'isFood': true,
      'mealName': 'Chicken burrito bowl',
      'components': [
        {
          'name': 'Chicken burrito bowl with white rice',
          'portionEstimate': 'one regular bowl',
          'carbsGrams': 62.0,
          'fatGrams': 22.0,
          'proteinGrams': 45.0,
          'confidence': 'medium',
        },
        {
          'name': 'Tortilla chips (small bag)',
          'portionEstimate': 'one small bag',
          'carbsGrams': 24.0,
          'fatGrams': 12.0,
          'proteinGrams': 3.0,
          'confidence': 'high',
        },
      ],
      'totalCarbsGrams': 86.0,
      'totalFatGrams': 34.0,
      'totalProteinGrams': 48.0,
      'mealSource': 'restaurant',
      'mealSourceRationale': 'Named chain dish.',
      'scaleReferenceDetected': false,
      'scaleReferenceNote': 'Assumed a regular bowl.',
      'absorptionHours': 5.0,
      'absorptionRationale': 'High fat and protein slow absorption.',
      'slowAbsorptionMeal': true,
      'overallConfidence': 'medium',
      'warnings': ['Portions vary between locations.'],
    };

    test('parses the structured estimate', () {
      final result = FoodSearchResult.fromJson(sample)!;
      expect(result.isFood, isTrue);
      expect(result.mealName, 'Chicken burrito bowl');
      expect(result.components, hasLength(2));
      expect(result.components.first.carbsGrams, 62.0);
      expect(result.components.first.confidence, 'medium');
      expect(result.totalCarbsGrams, 86.0);
      expect(result.absorptionHours, 5.0);
      expect(result.slowAbsorptionMeal, isTrue);
      expect(result.warnings.single, contains('Portions vary'));
    });

    test('tolerates missing optional fields and bad component entries', () {
      final result = FoodSearchResult.fromJson({
        'isFood': true,
        'mealName': 'Snack',
        'components': [
          {'name': ''},
          'not a map',
          {
            'name': 'Granola bar',
            'portionEstimate': '1 bar',
            'carbsGrams': 22,
            'fatGrams': 6,
            'proteinGrams': 3,
            'confidence': 'high',
          },
        ],
        'totalCarbsGrams': 22,
      })!;
      expect(result.components, hasLength(1));
      expect(result.components.single.name, 'Granola bar');
      expect(result.totalFatGrams, 0);
      expect(result.absorptionHours, 0);
      expect(result.warnings, isEmpty);
    });

    test('negative or non-numeric gram values are treated as zero', () {
      final result = FoodSearchResult.fromJson({
        'isFood': true,
        'mealName': 'Odd',
        'components': <dynamic>[],
        'totalCarbsGrams': -12,
        'totalFatGrams': 'lots',
      })!;
      expect(result.totalCarbsGrams, 0);
      expect(result.totalFatGrams, 0);
    });

    test('rejects non-map payloads', () {
      expect(FoodSearchResult.fromJson(null), isNull);
      expect(FoodSearchResult.fromJson('nope'), isNull);
      expect(FoodSearchResult.fromJson(<dynamic>[]), isNull);
    });
  });
}
