import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityEventualGlucoseView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    private var formattedEventualBG: String {
        guard let eventualBG = additionalState.eventualBG else { return "--" }

        // Match the caps used for the non-carb forecast curves so a runaway carb
        // forecast cannot surface an absurd value on the lock screen. Out-of-range
        // values keep an explicit ≤/≥ marker in both directions — a predicted severe
        // low must not silently render as a near-normal 39.
        let clamped = min(max(eventualBG, 39), 401)
        let prefix = eventualBG < 39 ? "≤" : (eventualBG > 401 ? "≥" : "")

        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.roundingMode = .halfUp

        if context.state.unit == GlucoseUnits.mgdL.rawValue {
            formatter.maximumFractionDigits = 0
            return prefix + (formatter.string(from: clamped as NSDecimalNumber) ?? "--")
        } else {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
            return prefix + (formatter.string(from: clamped.asMmolL as NSDecimalNumber) ?? "--")
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 3) {
                Text("⇢")
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(context.isStale ? .secondary : .primary)

                Text(formattedEventualBG)
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text(String(localized: "Eventual", comment: "Live Activity label for eventual glucose"))
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
