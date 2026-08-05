import Foundation

/// A common household object placed next to a meal to give the AI a real-world size reference.
enum ScaleReferenceObject: String, JSON, CaseIterable, Identifiable {
    case sodaCan
    case creditCard
    case fork
    case hand
    case none

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sodaCan:
            return String(localized: "Soda Can")
        case .creditCard:
            return String(localized: "Credit Card")
        case .fork:
            return String(localized: "Dinner Fork")
        case .hand:
            return String(localized: "Adult Hand")
        case .none:
            return String(localized: "No Reference")
        }
    }

    var iconName: String {
        switch self {
        case .sodaCan: return "cylinder"
        case .creditCard: return "creditcard"
        case .fork: return "fork.knife"
        case .hand: return "hand.raised"
        case .none: return "questionmark.circle"
        }
    }

    /// Real-world dimensions passed to the AI so it can derive the scale of the meal.
    var dimensionDescription: String {
        switch self {
        case .sodaCan:
            return "a standard 12 oz (355 ml) soda can, 6.6 cm in diameter and 12.2 cm tall"
        case .creditCard:
            return "a standard credit card, 8.56 cm wide and 5.40 cm tall"
        case .fork:
            return "a standard dinner fork, approximately 19 cm long"
        case .hand:
            return "an average adult hand, approximately 18 cm from wrist to fingertip"
        case .none:
            return "no reference object"
        }
    }

    /// Width : height aspect ratio of the camera overlay outline for this object.
    var overlayAspectRatio: CGFloat {
        switch self {
        case .sodaCan: return 66.0 / 122.0
        case .creditCard: return 85.6 / 54.0
        case .fork: return 30.0 / 190.0
        case .hand: return 100.0 / 180.0
        case .none: return 1.0
        }
    }
}

/// Where the meal most likely comes from, as judged by the AI.
enum MealSourceType: String, JSON {
    case homemade
    case restaurant
    case packaged
    case unknown

    var displayName: String {
        switch self {
        case .homemade: return String(localized: "Homemade")
        case .restaurant: return String(localized: "Restaurant")
        case .packaged: return String(localized: "Packaged")
        case .unknown: return String(localized: "Unknown")
        }
    }

    var iconName: String {
        switch self {
        case .homemade: return "house"
        case .restaurant: return "fork.knife.circle"
        case .packaged: return "shippingbox"
        case .unknown: return "questionmark.circle"
        }
    }
}

enum MealAnalysisConfidence: String, JSON {
    case low
    case medium
    case high

    var displayName: String {
        switch self {
        case .low: return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high: return String(localized: "High")
        }
    }
}

/// A single identified component of the meal (e.g. "white rice", "grilled chicken").
struct MealComponent: JSON, Identifiable, Equatable {
    var id: String { name }

    let name: String
    let portionEstimate: String
    let carbsGrams: Decimal
    let fatGrams: Decimal
    let proteinGrams: Decimal
    let confidence: MealAnalysisConfidence
}

/// The full structured result returned by the AI for one meal photo.
struct MealPhotoAnalysisResult: JSON, Equatable {
    /// Whether the photo actually contains food.
    let isFood: Bool
    /// A short display name for the whole meal, e.g. "Chicken burrito bowl".
    let mealName: String
    let components: [MealComponent]
    let totalCarbsGrams: Decimal
    let totalFatGrams: Decimal
    let totalProteinGrams: Decimal
    /// Homemade vs restaurant vs packaged judgement.
    let mealSource: MealSourceType
    let mealSourceRationale: String
    /// Whether the requested scale-reference object was found in the photo.
    let scaleReferenceDetected: Bool
    let scaleReferenceNote: String
    /// Estimated carb absorption duration in hours based on the types of carbohydrates and fat/protein content.
    let absorptionHours: Decimal
    let absorptionRationale: String
    /// True when fat/protein content suggests slow absorption (candidate for a reduced initial bolus).
    let slowAbsorptionMeal: Bool
    let overallConfidence: MealAnalysisConfidence
    let warnings: [String]
}
