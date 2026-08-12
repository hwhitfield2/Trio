import Foundation
import SwiftUI
import WidgetKit

struct LiveActivityIOBLabelView: View {
    var context: ActivityViewContext<LiveActivityAttributes>
    var additionalState: LiveActivityAttributes.ContentAdditionalState

    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text(NumberFormatter.insulinFormatter.string(from: additionalState.iob as NSNumber) ?? "--")
                    .fontWeight(.bold)
                    .font(.title3)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))

                Text(String(localized: "U", comment: "Insulin unit"))
                    .font(.headline).fontWeight(.bold)
                    .foregroundStyle(context.isStale ? .secondary : .primary)
                    .strikethrough(context.isStale, pattern: .solid, color: .red.opacity(0.6))
            }
            Text("IOB")
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
    }
}
