import Foundation
import Swinject

enum FoodSearchError: LocalizedError {
    case missingAPIKey
    case emptyQuery
    case badStatusCode(Int, String?)
    case refused
    case noFoodFound
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(
                localized: "No AI API key configured. Add your Anthropic API key in Settings > Features > Meal Settings."
            )
        case .emptyQuery:
            return String(localized: "Please describe the food you want to look up.")
        case let .badStatusCode(code, message):
            if let message = message, !message.isEmpty {
                return String(localized: "The AI service returned an error (\(code)): \(message)")
            }
            return String(localized: "The AI service returned an error (\(code)). Please try again.")
        case .refused:
            return String(localized: "The AI declined to look up this food. Please try a different description.")
        case .noFoodFound:
            return String(localized: "No food could be identified from this description. Try adding the restaurant and dish name.")
        case .invalidResponse:
            return String(localized: "The AI returned an unexpected response. Please try again.")
        }
    }
}

protocol FoodSearchManager {
    /// Whether an API key is stored and the feature can run.
    var isConfigured: Bool { get }
    /// Looks up a free-text food description (e.g. a restaurant dish) and returns
    /// structured carb/fat/protein and absorption estimates.
    func searchFood(query: String) async throws -> MealPhotoAnalysisResult
}

/// Text-based counterpart to the meal photo analysis: type what you are eating
/// ("Chipotle chicken burrito bowl with white rice and black beans") and the AI
/// returns the same structured estimate the photo flow produces. Reuses the meal
/// photo API key, endpoint, and result schema.
final class BaseFoodSearchManager: FoodSearchManager, Injectable {
    @Injected() private var keychain: Keychain!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    var isConfigured: Bool {
        guard let key = keychain.getValue(String.self, forKey: MealPhotoAnalysis.Config.apiKeyKey) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func searchFood(query: String) async throws -> MealPhotoAnalysisResult {
        guard let apiKey = keychain.getValue(String.self, forKey: MealPhotoAnalysis.Config.apiKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw FoodSearchError.missingAPIKey
        }

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw FoodSearchError.emptyQuery
        }

        let request = try buildRequest(apiKey: apiKey, query: trimmedQuery)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FoodSearchError.invalidResponse
        }

        guard 200 ..< 300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data)
            debug(.service, "Food search failed with status \(http.statusCode)")
            throw FoodSearchError.badStatusCode(http.statusCode, apiError?.error.message)
        }

        let message = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)

        // Safety classifiers can decline a request with HTTP 200 and stop_reason "refusal".
        if message.stopReason == "refusal" {
            throw FoodSearchError.refused
        }

        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let resultData = text.data(using: .utf8)
        else {
            throw FoodSearchError.invalidResponse
        }

        let result: MealPhotoAnalysisResult
        do {
            result = try JSONDecoder().decode(MealPhotoAnalysisResult.self, from: resultData)
        } catch {
            debug(.service, "Food search JSON decoding failed: \(error)")
            throw FoodSearchError.invalidResponse
        }

        guard result.isFood else {
            throw FoodSearchError.noFoodFound
        }

        return result
    }

    private func buildRequest(apiKey: String, query: String) throws -> URLRequest {
        var request = URLRequest(url: MealPhotoAnalysis.Config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(MealPhotoAnalysis.Config.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = MealPhotoAnalysis.Config.timeout

        let body: [String: Any] = [
            "model": MealPhotoAnalysis.Config.model,
            "max_tokens": MealPhotoAnalysis.Config.maxTokens,
            "output_config": ["format": ["type": "json_schema", "schema": BaseMealPhotoAnalysisManager.resultSchema]],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "text",
                            "text": Self.prompt(for: query)
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func prompt(for query: String) -> String {
        """
        You are assisting a person with diabetes who uses an automated insulin delivery system. They are about to eat and have described their food in text - often a restaurant dish - and need carbohydrate estimates to dose insulin.

        Their description:
        "\(query)"

        Perform the following analysis:
        1. Verify the description refers to food or drink. If it does not, set isFood to false and leave the other fields as sensible empty defaults.
        2. Identify each distinct food component the description implies (including typical sides, sauces, and drinks that are explicitly mentioned). If the description names a specific restaurant or chain, use published nutrition information for that restaurant's dishes where you know it; otherwise use typical restaurant portion sizes. Do not invent items that were not mentioned.
        3. When the portion size is not stated, assume a standard single serving of that dish and state the assumed portion in portionEstimate so the user can correct it.
        4. Estimate carbohydrates, fat, and protein in grams for each component and in total. Be realistic and slightly conservative rather than overestimating carbs.
        5. Set mealSource to restaurant when a restaurant or takeout dish is described, packaged for packaged snacks or drinks, homemade when clearly home-cooked, and unknown otherwise. Explain the reasoning in mealSourceRationale. Restaurant and packaged meals often contain more hidden fat and sugar - account for that in your estimates and mention it.
        6. Set scaleReferenceDetected to false and use scaleReferenceNote to state the portion assumptions you made (this lookup has no photo to measure from).
        7. Estimate how long the carbohydrates will take to absorb (absorptionHours, typically 2-4 hours for fast carbs, up to 6-8 for high-fat/high-protein or very large meals), based on the glycemic character of the carbs and the fat/protein content. Explain the reasoning in absorptionRationale. Set slowAbsorptionMeal to true when high fat or protein content will meaningfully delay glucose rise.
        8. Set overallConfidence honestly - lower it when the description is vague about portions or preparation. Add warnings for anything the user should verify (hidden sauces, sugary drinks, uncertain portions, restaurant-to-restaurant variation).

        The estimates will be reviewed by the user before being used in insulin dosing calculations, but accuracy still matters greatly.
        """
    }
}
