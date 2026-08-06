import Foundation
import Swinject
import UIKit

enum MealPhotoAnalysis {
    enum Config {
        static let apiKeyKey = "MealPhotoAnalysis.apiKey"
        static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
        static let apiVersion = "2023-06-01"
        static let model = "claude-opus-5"
        static let maxTokens = 16000
        static let timeout: TimeInterval = 180
        /// Longest image edge sent to the API; larger photos are downscaled to control cost.
        static let maxImageDimension: CGFloat = 1568
        static let jpegQuality: CGFloat = 0.7
    }
}

enum MealPhotoAnalysisError: LocalizedError {
    case missingAPIKey
    case invalidImage
    case badStatusCode(Int, String?)
    case refused
    case noFoodDetected
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return String(
                localized: "No AI API key configured. Add your Anthropic API key in Settings > Features > Meal Settings."
            )
        case .invalidImage:
            return String(localized: "The photo could not be processed. Please try again.")
        case let .badStatusCode(code, message):
            if let message = message, !message.isEmpty {
                return String(localized: "The AI service returned an error (\(code)): \(message)")
            }
            return String(localized: "The AI service returned an error (\(code)). Please try again.")
        case .refused:
            return String(localized: "The AI declined to analyze this photo. Please try a different photo.")
        case .noFoodDetected:
            return String(localized: "No food was detected in this photo. Please retake the photo of your meal.")
        case .invalidResponse:
            return String(localized: "The AI returned an unexpected response. Please try again.")
        }
    }
}

protocol MealPhotoAnalysisManager {
    /// Whether an API key is stored and the feature can run.
    var isConfigured: Bool { get }
    /// Analyzes a meal photo and returns structured carb/fat/protein and absorption estimates.
    func analyzeMealPhoto(_ image: UIImage, scaleReference: ScaleReferenceObject) async throws -> MealPhotoAnalysisResult
}

final class BaseMealPhotoAnalysisManager: MealPhotoAnalysisManager, Injectable {
    @Injected() private var keychain: Keychain!

    init(resolver: Resolver) {
        injectServices(resolver)
    }

    var isConfigured: Bool {
        guard let key = keychain.getValue(String.self, forKey: MealPhotoAnalysis.Config.apiKeyKey) else { return false }
        return !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func analyzeMealPhoto(
        _ image: UIImage,
        scaleReference: ScaleReferenceObject
    ) async throws -> MealPhotoAnalysisResult {
        guard let apiKey = keychain.getValue(String.self, forKey: MealPhotoAnalysis.Config.apiKeyKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw MealPhotoAnalysisError.missingAPIKey
        }

        guard let imageData = Self.preparedJPEGData(from: image) else {
            throw MealPhotoAnalysisError.invalidImage
        }

        let request = try buildRequest(apiKey: apiKey, imageData: imageData, scaleReference: scaleReference)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw MealPhotoAnalysisError.invalidResponse
        }

        guard 200 ..< 300 ~= http.statusCode else {
            let apiError = try? JSONDecoder().decode(AnthropicErrorEnvelope.self, from: data)
            debug(.service, "Meal photo analysis failed with status \(http.statusCode)")
            throw MealPhotoAnalysisError.badStatusCode(http.statusCode, apiError?.error.message)
        }

        let message = try JSONDecoder().decode(AnthropicMessageResponse.self, from: data)

        // Safety classifiers can decline a request with HTTP 200 and stop_reason "refusal".
        if message.stopReason == "refusal" {
            throw MealPhotoAnalysisError.refused
        }

        guard let text = message.content.first(where: { $0.type == "text" })?.text,
              let resultData = text.data(using: .utf8)
        else {
            throw MealPhotoAnalysisError.invalidResponse
        }

        let result: MealPhotoAnalysisResult
        do {
            result = try JSONDecoder().decode(MealPhotoAnalysisResult.self, from: resultData)
        } catch {
            debug(.service, "Meal photo analysis JSON decoding failed: \(error)")
            throw MealPhotoAnalysisError.invalidResponse
        }

        guard result.isFood else {
            throw MealPhotoAnalysisError.noFoodDetected
        }

        return result
    }

    // MARK: - Image preparation

    /// Downscales the photo to the configured maximum edge length and encodes it as JPEG.
    static func preparedJPEGData(from image: UIImage) -> Data? {
        let maxDimension = MealPhotoAnalysis.Config.maxImageDimension
        let size = image.size
        let largestEdge = max(size.width, size.height)

        guard largestEdge > 0 else { return nil }

        var scaled = image
        if largestEdge > maxDimension {
            let scale = maxDimension / largestEdge
            let newSize = CGSize(width: size.width * scale, height: size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            scaled = UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
                image.draw(in: CGRect(origin: .zero, size: newSize))
            }
        }

        return scaled.jpegData(compressionQuality: MealPhotoAnalysis.Config.jpegQuality)
    }

    // MARK: - Request building

    private func buildRequest(
        apiKey: String,
        imageData: Data,
        scaleReference: ScaleReferenceObject
    ) throws -> URLRequest {
        var request = URLRequest(url: MealPhotoAnalysis.Config.endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(MealPhotoAnalysis.Config.apiVersion, forHTTPHeaderField: "anthropic-version")
        request.timeoutInterval = MealPhotoAnalysis.Config.timeout

        let body: [String: Any] = [
            "model": MealPhotoAnalysis.Config.model,
            "max_tokens": MealPhotoAnalysis.Config.maxTokens,
            "output_config": ["format": ["type": "json_schema", "schema": Self.resultSchema]],
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": imageData.base64EncodedString()
                            ]
                        ],
                        [
                            "type": "text",
                            "text": Self.prompt(for: scaleReference)
                        ]
                    ]
                ]
            ]
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private static func prompt(for scaleReference: ScaleReferenceObject) -> String {
        let referenceInstruction: String
        if scaleReference == .none {
            referenceInstruction =
                "No scale-reference object was placed in the photo. Estimate portion sizes from plate/bowl size and other visual context, and set scaleReferenceDetected to false with a note that no reference was used."
        } else {
            referenceInstruction =
                "The user placed \(scaleReference.dimensionDescription) next to the meal as a scale reference. First locate this object in the photo and use its known real-world size to determine the scale of the meal and the portion sizes. Set scaleReferenceDetected to true only if you can clearly see it; if you cannot find it, set it to false, explain that in scaleReferenceNote, estimate scale from other context, and lower your confidence."
        }

        return """
        You are assisting a person with diabetes who uses an automated insulin delivery system. Analyze this photo of a meal.

        \(referenceInstruction)

        Perform the following analysis:
        1. Verify the photo contains food. If it does not, set isFood to false and leave the other fields as sensible empty defaults.
        2. Identify each distinct food component and estimate its portion size (in common measures like grams, cups, or pieces) using the scale reference.
        3. Estimate carbohydrates, fat, and protein in grams for each component and in total. Be realistic and slightly conservative rather than overestimating carbs.
        4. Judge whether the meal is homemade, from a restaurant, or packaged/processed, and explain the visual evidence (plating, packaging, containers, garnish, portion uniformity). Restaurant and packaged meals often contain more hidden fat and sugar - account for that in your estimates and mention it.
        5. Estimate how long the carbohydrates will take to absorb (absorptionHours, typically 2-4 hours for fast carbs, up to 6-8 for high-fat/high-protein or very large meals), based on the glycemic character of the carbs and the fat/protein content. Explain the reasoning in absorptionRationale. Set slowAbsorptionMeal to true when high fat or protein content will meaningfully delay glucose rise.
        6. Set overallConfidence honestly. Add warnings for anything the user should verify (hidden sauces, sugary drinks, uncertain portions, obscured food).

        The estimates will be reviewed by the user before being used in insulin dosing calculations, but accuracy still matters greatly.
        """
    }

    /// JSON schema enforced via structured outputs so the reply always decodes into
    /// `MealPhotoAnalysisResult`. Shared with the text-based food search, which returns
    /// the same structure.
    static let resultSchema: [String: Any] = [
        "type": "object",
        "additionalProperties": false,
        "required": [
            "isFood", "mealName", "components", "totalCarbsGrams", "totalFatGrams", "totalProteinGrams",
            "mealSource", "mealSourceRationale", "scaleReferenceDetected", "scaleReferenceNote",
            "absorptionHours", "absorptionRationale", "slowAbsorptionMeal", "overallConfidence", "warnings"
        ],
        "properties": [
            "isFood": ["type": "boolean"],
            "mealName": ["type": "string", "description": "Short display name for the whole meal"],
            "components": [
                "type": "array",
                "items": [
                    "type": "object",
                    "additionalProperties": false,
                    "required": ["name", "portionEstimate", "carbsGrams", "fatGrams", "proteinGrams", "confidence"],
                    "properties": [
                        "name": ["type": "string"],
                        "portionEstimate": ["type": "string"],
                        "carbsGrams": ["type": "number"],
                        "fatGrams": ["type": "number"],
                        "proteinGrams": ["type": "number"],
                        "confidence": ["type": "string", "enum": ["low", "medium", "high"]]
                    ]
                ]
            ],
            "totalCarbsGrams": ["type": "number"],
            "totalFatGrams": ["type": "number"],
            "totalProteinGrams": ["type": "number"],
            "mealSource": ["type": "string", "enum": ["homemade", "restaurant", "packaged", "unknown"]],
            "mealSourceRationale": ["type": "string"],
            "scaleReferenceDetected": ["type": "boolean"],
            "scaleReferenceNote": ["type": "string"],
            "absorptionHours": ["type": "number"],
            "absorptionRationale": ["type": "string"],
            "slowAbsorptionMeal": ["type": "boolean"],
            "overallConfidence": ["type": "string", "enum": ["low", "medium", "high"]],
            "warnings": ["type": "array", "items": ["type": "string"]]
        ]
    ]
}

// MARK: - Anthropic API response models (shared with FoodSearchManager)

struct AnthropicMessageResponse: Decodable {
    struct ContentBlock: Decodable {
        let type: String
        let text: String?
    }

    let content: [ContentBlock]
    let stopReason: String?

    enum CodingKeys: String, CodingKey {
        case content
        case stopReason = "stop_reason"
    }
}

struct AnthropicErrorEnvelope: Decodable {
    struct APIError: Decodable {
        let message: String
    }

    let error: APIError
}
