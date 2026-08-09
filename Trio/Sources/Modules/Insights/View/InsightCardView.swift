import SwiftUI

extension InsightSeverity {
    var tintColor: Color {
        switch self {
        case .info: return .secondary
        case .notable: return .blue
        case .attention: return .orange
        }
    }
}

struct InsightCardView: View {
    let card: InsightCard

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: card.sfSymbol)
                .font(.title3)
                .foregroundStyle(card.severity.tintColor)
                .frame(width: 28, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(card.headline)
                    .font(.headline)
                Text(card.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(card.evidenceLine)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}
