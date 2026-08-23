import 'dart:convert';
import 'dart:io';

import '../models/food_search_result.dart';
import '../models/pairing_bundle.dart';

class FoodSearchException implements Exception {
  const FoodSearchException(this.message);
  final String message;

  @override
  String toString() => message;
}

/// Text-based AI food lookup — the same feature the Trio host offers from its
/// carbs entry, run with the credentials the host shares during pairing (and
/// keeps current through status snapshots). The endpoint, request shape,
/// prompt and result schema mirror the host's `BaseFoodSearchManager`
/// (Trio/Sources/Services/MealPhotoAI/FoodSearchManager.swift) — keep both
/// sides in sync so host and follower review identical estimates.
class FoodSearchService {
  FoodSearchService(this.config, {HttpClient? client}) : _client = client ?? HttpClient();

  final AiConfig config;
  final HttpClient _client;

  static final Uri _endpoint = Uri.parse('https://api.anthropic.com/v1/messages');
  static const _apiVersion = '2023-06-01';
  static const _maxTokens = 4000;
  static const _timeout = Duration(seconds: 180);

  Future<FoodSearchResult> search(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) {
      throw const FoodSearchException('Please describe the food you want to look up.');
    }

    final HttpClientResponse response;
    final String body;
    try {
      final request = await _client.postUrl(_endpoint).timeout(_timeout);
      request.headers.contentType = ContentType.json;
      request.headers.set('x-api-key', config.apiKey);
      request.headers.set('anthropic-version', _apiVersion);
      request.write(jsonEncode(_requestBody(trimmed)));
      response = await request.close().timeout(_timeout);
      body = await response.transform(utf8.decoder).join().timeout(_timeout);
    } on FoodSearchException {
      rethrow;
    } catch (_) {
      throw const FoodSearchException(
          'Could not reach the AI service. Check the internet connection and try again.');
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw FoodSearchException(_apiErrorMessage(response.statusCode, body));
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const FoodSearchException('The AI returned an unexpected response. Please try again.');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FoodSearchException('The AI returned an unexpected response. Please try again.');
    }

    // Safety classifiers can decline with HTTP 200 and stop_reason "refusal".
    if (decoded['stop_reason'] == 'refusal') {
      throw const FoodSearchException(
          'The AI declined to look up this food. Please try a different description.');
    }

    final content = decoded['content'];
    String? text;
    if (content is List) {
      for (final block in content) {
        if (block is Map<String, dynamic> && block['type'] == 'text' && block['text'] is String) {
          text = block['text'] as String;
          break;
        }
      }
    }
    if (text == null) {
      throw const FoodSearchException('The AI returned an unexpected response. Please try again.');
    }

    final FoodSearchResult? result;
    try {
      result = FoodSearchResult.fromJson(jsonDecode(text));
    } on FormatException {
      throw const FoodSearchException('The AI returned an unexpected response. Please try again.');
    }
    if (result == null) {
      throw const FoodSearchException('The AI returned an unexpected response. Please try again.');
    }
    if (!result.isFood) {
      throw const FoodSearchException(
          'No food could be identified from this description. Try adding the restaurant and dish name.');
    }
    return result;
  }

  static String _apiErrorMessage(int status, String body) {
    // Spelled as nested ifs rather than a conditional expression: after
    // `is Map<String, dynamic>` the parser reads a following `?` as a
    // nullable type test, not as the ternary.
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          final message = error['message'];
          if (message is String && message.isNotEmpty) {
            return 'The AI service returned an error ($status): $message';
          }
        }
      }
    } catch (_) {}
    return 'The AI service returned an error ($status). Please try again.';
  }

  Map<String, dynamic> _requestBody(String query) => {
        'model': config.model,
        'max_tokens': _maxTokens,
        'output_config': {
          'format': {'type': 'json_schema', 'schema': _resultSchema}
        },
        'messages': [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': _prompt(query)}
            ]
          }
        ],
      };

  /// Mirrors the host's food search prompt word for word.
  static String _prompt(String query) => '''
You are assisting a person with diabetes who uses an automated insulin delivery system. They are about to eat and have described their food in text - often a restaurant dish - and need carbohydrate estimates to dose insulin.

Their description:
"$query"

Perform the following analysis:
1. Verify the description refers to food or drink. If it does not, set isFood to false and leave the other fields as sensible empty defaults.
2. Make each component one separately orderable item (e.g. "Chicken McNuggets (10 pc)", "Medium Fries", "Ketchup packet") so the user can scale the quantity of each item independently in the app. If the description names a specific restaurant or chain, use published nutrition information for that restaurant's dishes where you know it; otherwise use typical restaurant portion sizes. Do not invent items that were not mentioned.
3. If a quantity or size is stated ("20 piece nuggets", "large fries", "two tacos"), use it exactly. When it is not stated, assume the smallest standard serving of that item and state the assumed count or size in both the component name and portionEstimate - the user will multiply the quantity in the app if they ordered more.
4. Estimate carbohydrates, fat, and protein in grams for each component and in total. Be realistic and slightly conservative rather than overestimating carbs.
5. Set mealSource to restaurant when a restaurant or takeout dish is described, packaged for packaged snacks or drinks, homemade when clearly home-cooked, and unknown otherwise. Explain the reasoning in mealSourceRationale. Restaurant and packaged meals often contain more hidden fat and sugar - account for that in your estimates and mention it.
6. Set scaleReferenceDetected to false and use scaleReferenceNote to state the portion assumptions you made (this lookup has no photo to measure from).
7. Estimate how long the carbohydrates will take to absorb (absorptionHours, typically 2-4 hours for fast carbs, up to 6-8 for high-fat/high-protein or very large meals), based on the glycemic character of the carbs and the fat/protein content. Explain the reasoning in absorptionRationale. Set slowAbsorptionMeal to true when high fat or protein content will meaningfully delay glucose rise.
8. Set overallConfidence honestly - lower it when the description is vague about portions or preparation. Add warnings for anything the user should verify (hidden sauces, sugary drinks, uncertain portions, restaurant-to-restaurant variation).

The estimates will be reviewed by the user before being used in insulin dosing calculations, but accuracy still matters greatly.
''';

  /// The host's `BaseMealPhotoAnalysisManager.resultSchema`, verbatim.
  static const Map<String, dynamic> _resultSchema = {
    'type': 'object',
    'additionalProperties': false,
    'required': [
      'isFood',
      'mealName',
      'components',
      'totalCarbsGrams',
      'totalFatGrams',
      'totalProteinGrams',
      'mealSource',
      'mealSourceRationale',
      'scaleReferenceDetected',
      'scaleReferenceNote',
      'absorptionHours',
      'absorptionRationale',
      'slowAbsorptionMeal',
      'overallConfidence',
      'warnings'
    ],
    'properties': {
      'isFood': {'type': 'boolean'},
      'mealName': {'type': 'string', 'description': 'Short display name for the whole meal'},
      'components': {
        'type': 'array',
        'items': {
          'type': 'object',
          'additionalProperties': false,
          'required': ['name', 'portionEstimate', 'carbsGrams', 'fatGrams', 'proteinGrams', 'confidence'],
          'properties': {
            'name': {'type': 'string'},
            'portionEstimate': {'type': 'string'},
            'carbsGrams': {'type': 'number'},
            'fatGrams': {'type': 'number'},
            'proteinGrams': {'type': 'number'},
            'confidence': {
              'type': 'string',
              'enum': ['low', 'medium', 'high']
            }
          }
        }
      },
      'totalCarbsGrams': {'type': 'number'},
      'totalFatGrams': {'type': 'number'},
      'totalProteinGrams': {'type': 'number'},
      'mealSource': {
        'type': 'string',
        'enum': ['homemade', 'restaurant', 'packaged', 'unknown']
      },
      'mealSourceRationale': {'type': 'string'},
      'scaleReferenceDetected': {'type': 'boolean'},
      'scaleReferenceNote': {'type': 'string'},
      'absorptionHours': {'type': 'number'},
      'absorptionRationale': {'type': 'string'},
      'slowAbsorptionMeal': {'type': 'boolean'},
      'overallConfidence': {
        'type': 'string',
        'enum': ['low', 'medium', 'high']
      },
      'warnings': {
        'type': 'array',
        'items': {'type': 'string'}
      }
    }
  };
}
