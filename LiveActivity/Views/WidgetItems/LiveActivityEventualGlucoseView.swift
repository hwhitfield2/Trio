import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityEventualGlucoseView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    private var formattedEventualBG: String {
        additionalState.formattedEventualBG(unit: context.state.unit)
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
