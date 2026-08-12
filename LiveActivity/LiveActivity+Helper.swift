//
//  LiveActivity+Helper.swift
//  LiveActivityExtension
//
//  Created by Cengiz Deniz on 17.10.24.
//
import ActivityKit
import Charts
import SwiftUI
import WidgetKit

enum Size {
    case minimal
    case compact
    case expanded
}

enum GlucoseUnits: String, Equatable {
    case mgdL = "mg/dL"
    case mmolL = "mmol/L"

    static let exchangeRate: Decimal = 0.0555
}

enum GlucoseColorScheme: String, Equatable {
    case staticColor
    case dynamicColor
}

func rounded(_ value: Decimal, scale: Int, roundingMode: NSDecimalNumber.RoundingMode) -> Decimal {
    var result = Decimal()
    var toRound = value
    NSDecimalRound(&result, &toRound, scale, roundingMode)
    return result
}

extension Int {
    var asMmolL: Decimal {
        rounded(Decimal(self) * GlucoseUnits.exchangeRate, scale: 1, roundingMode: .plain)
    }

    var formattedAsMmolL: String {
        NumberFormatter.glucoseFormatter.string(from: asMmolL as NSDecimalNumber) ?? "\(asMmolL)"
    }
}

extension Decimal {
    var asMmolL: Decimal {
        rounded(self * GlucoseUnits.exchangeRate, scale: 1, roundingMode: .plain)
    }

    var asMgdL: Decimal {
        rounded(self / GlucoseUnits.exchangeRate, scale: 0, roundingMode: .plain)
    }

    var formattedAsMmolL: String {
        NumberFormatter.glucoseFormatter.string(from: asMmolL as NSDecimalNumber) ?? "\(asMmolL)"
    }
}

extension NumberFormatter {
    static let glucoseFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.locale = Locale.current
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        return formatter
    }()

    /// Formatter for insulin amounts, i.e. IOB and total daily dose.
    static let insulinFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        return formatter
    }()
}

extension DateFormatter {
    /// Formatter for the "updated" timestamps shown in the live activity and the widgets.
    static let updatedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

extension LiveActivityAttributes.ContentState {
    /// Whether the user picked the static (red / green / orange) glucose color scheme.
    var hasStaticColorScheme: Bool {
        glucoseColorScheme == GlucoseColorScheme.staticColor.rawValue
    }

    /// The color of the currently displayed glucose value.
    ///
    /// Shared by the lock screen live activity, the dynamic island and the widgets so that they can
    /// never disagree about what "in range" looks like.
    var glucoseColor: Color {
        let isMgdL = unit == GlucoseUnits.mgdL.rawValue

        // TODO: workaround for now: set low value to 55, to have dynamic color shades between 55 and user-set low (approx. 70); same for high glucose
        let hardCodedLow = isMgdL ? Decimal(55) : 55.asMmolL
        let hardCodedHigh = isMgdL ? Decimal(220) : 220.asMmolL

        return Color.getDynamicGlucoseColor(
            glucoseValue: Decimal(string: bg) ?? 100,
            highGlucoseColorValue: !hasStaticColorScheme ? hardCodedHigh : (isMgdL ? highGlucose : highGlucose.asMmolL),
            lowGlucoseColorValue: !hasStaticColorScheme ? hardCodedLow : (isMgdL ? lowGlucose : lowGlucose.asMmolL),
            targetGlucose: isMgdL ? target : target.asMmolL,
            glucoseColorScheme: glucoseColorScheme
        )
    }

    /// The glucose delta with the padding the live activity formatter adds stripped off.
    var trimmedChange: String {
        change.trimmingCharacters(in: .whitespaces)
    }

    /// The timestamp shown in the "updated" label, or a placeholder if there is no determination yet.
    var formattedUpdatedTime: String {
        guard let date else { return "--" }

        return DateFormatter.updatedTimeFormatter.string(from: date)
    }
}

extension LiveActivityAttributes.ContentAdditionalState {
    /// The predicted eventual glucose, formatted for the given glucose unit.
    ///
    /// Matches the caps used for the non-carb forecast curves so a runaway carb forecast cannot
    /// surface an absurd value. Out-of-range values keep an explicit ≤/≥ marker in both directions -
    /// a predicted severe low must not silently render as a near-normal 39.
    func formattedEventualBG(unit: String) -> String {
        guard let eventualBG else { return "--" }

        let clamped = min(max(eventualBG, 39), 401)
        let prefix = eventualBG < 39 ? "≤" : (eventualBG > 401 ? "≥" : "")

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp

        if unit == GlucoseUnits.mgdL.rawValue {
            formatter.maximumFractionDigits = 0
            return prefix + (formatter.string(from: clamped as NSDecimalNumber) ?? "--")
        } else {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return prefix + (formatter.string(from: clamped.asMmolL as NSDecimalNumber) ?? "--")
        }
    }
}

extension Color {
    // Helper function to decide how to pick the glucose color
    static func getDynamicGlucoseColor(
        glucoseValue: Decimal,
        highGlucoseColorValue: Decimal,
        lowGlucoseColorValue: Decimal,
        targetGlucose: Decimal,
        glucoseColorScheme: String
    ) -> Color {
        // Only use calculateHueBasedGlucoseColor if the setting is enabled in preferences
        if glucoseColorScheme == "dynamicColor" {
            return calculateHueBasedGlucoseColor(
                glucoseValue: glucoseValue,
                highGlucose: highGlucoseColorValue,
                lowGlucose: lowGlucoseColorValue,
                targetGlucose: targetGlucose
            )
        }
        // Otheriwse, use static (orange = high, red = low, green = range)
        else {
            if glucoseValue >= highGlucoseColorValue {
                return Color.orange
            } else if glucoseValue <= lowGlucoseColorValue {
                return Color.red
            } else {
                return Color.green
            }
        }
    }

    // Dynamic color - Define the hue values for the key points
    // We'll shift color gradually one glucose point at a time
    // We'll shift through the rainbow colors of ROY-G-BIV from low to high
    // Start at red for lowGlucose, green for targetGlucose, and violet for highGlucose
    private static func calculateHueBasedGlucoseColor(
        glucoseValue: Decimal,
        highGlucose: Decimal,
        lowGlucose: Decimal,
        targetGlucose: Decimal
    ) -> Color {
        let redHue: CGFloat = 0.0 / 360.0 // 0 degrees
        let greenHue: CGFloat = 120.0 / 360.0 // 120 degrees
        let purpleHue: CGFloat = 270.0 / 360.0 // 270 degrees

        // Calculate the hue based on the bgLevel
        var hue: CGFloat
        if glucoseValue <= lowGlucose {
            hue = redHue
        } else if glucoseValue >= highGlucose {
            hue = purpleHue
        } else if glucoseValue <= targetGlucose {
            // Interpolate between red and green
            let ratio = CGFloat(truncating: (glucoseValue - lowGlucose) / (targetGlucose - lowGlucose) as NSNumber)

            hue = redHue + ratio * (greenHue - redHue)
        } else {
            // Interpolate between green and purple
            let ratio = CGFloat(truncating: (glucoseValue - targetGlucose) / (highGlucose - targetGlucose) as NSNumber)
            hue = greenHue + ratio * (purpleHue - greenHue)
        }
        // Return the color with full saturation and brightness
        let color = Color(hue: hue, saturation: 0.6, brightness: 0.9)
        return color
    }
}

func bgAndTrend(
    context: ActivityViewContext<LiveActivityAttributes>,
    size: Size,
    glucoseColor: Color
) -> (some View, Int) {
    let hasStaticColorScheme = context.state.glucoseColorScheme == "staticColor"

    var characters = 0

    let bgText = context.state.bg
    characters += bgText.count

    // narrow mode is for the minimal dynamic island view
    // there is not enough space to show all three arrow there
    // and everything has to be squeezed together to some degree
    // only display the first arrow character and make it red in case there were more characters
    var directionText: String?
    if let direction = context.state.direction {
        if size == .compact || size == .minimal {
            directionText = String(direction[direction.startIndex ... direction.startIndex])
        } else {
            directionText = direction
        }

        characters += directionText!.count
    }

    let spacing: CGFloat
    switch size {
    case .minimal: spacing = -1
    case .compact: spacing = 0
    case .expanded: spacing = 3
    }

    let stack = HStack(spacing: spacing) {
        Text(bgText)
            .foregroundStyle(hasStaticColorScheme ? .primary : glucoseColor)
            .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
        if let direction = directionText {
            let text = Text(direction)
            switch size {
            case .minimal:
                let scaledText = text.scaleEffect(x: 0.7, y: 0.7, anchor: .leading)
                scaledText.foregroundStyle(hasStaticColorScheme ? .primary : glucoseColor)

            case .compact:
                text.scaleEffect(x: 0.8, y: 0.8, anchor: .leading).padding(.trailing, -3)

            case .expanded:
                text.scaleEffect(x: 0.7, y: 0.7, anchor: .leading).padding(.trailing, -5)
            }
        }
    }.foregroundStyle(hasStaticColorScheme ? .primary : glucoseColor)
        .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

    return (stack, characters)
}

private struct LiveActivityWatchOS: EnvironmentKey {
    // Value to add support for older iOS version (17 and lower) in order to keep using the ActivityFamily class
    static let defaultValue = false
}

public extension EnvironmentValues {
    var isWatchOS: Bool {
        get { self[LiveActivityWatchOS.self] }
        set { self[LiveActivityWatchOS.self] = newValue }
    }
}

@available(iOS 18, *) struct LiveActivityWatchOSModifier: ViewModifier {
    @Environment(\.activityFamily) var activityFamily

    func body(content: Content) -> some View {
        content.environment(\.isWatchOS, activityFamily == .small)
    }
}

extension View {
    @ViewBuilder func addIsWatchOS() -> some View {
        if #available(iOS 18, *) {
            modifier(LiveActivityWatchOSModifier())
        } else {
            self
        }
    }

    @ViewBuilder func addLiveActivityModifiers(isWatchOS: Bool) -> some View {
        modifier(LiveActivityModifiers(isWatchOS: isWatchOS))
    }
}

struct LiveActivityModifiers: ViewModifier {
    let isWatchOS: Bool

    func body(content: Content) -> some View {
        content
            .padding(.all, isWatchOS ? 10 : 14)
            .frame(minHeight: 0, maxHeight: .infinity)
            .privacySensitive()
            // Semantic BackgroundStyle and Color values work here. They adapt to the given interface style (light mode, dark
            // mode)
            // Semantic UIColors do NOT (as of iOS 17.1.1). Like UIColor.systemBackgroundColor (it does not adapt to changes of
            // the interface style)
            // The colorScheme environment variable does work here, but BackgroundStyle gives us this functionality for free
            .foregroundStyle(Color.primary)
            .background(BackgroundStyle.background.opacity(isWatchOS ? 1 : 0.4))
            .activityBackgroundTint(isWatchOS ? .black : Color.clear)
    }
}
