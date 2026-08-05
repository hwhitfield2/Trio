import CoreData
import SwiftUI

/// Detail payload shown when a status tile is pressed: title, explanatory body,
/// and shortcut actions that route into existing screens.
struct HomeTileDetail: Identifiable {
    struct Action: Identifiable {
        let id = UUID()
        let name: String
        let icon: String
        let action: () -> Void
    }

    let id = UUID()
    let title: String
    let body: String
    let actions: [Action]
}

/// One cell of the 4-column metric strip (IOB / COB / Basal / Eventual).
struct HomeMetricTile: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let isHighlighted: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(label)
                    .glassCaption()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
        .background(isHighlighted ? Color.tabBar.opacity(0.18) : Color.clear)
        .contentShape(Rectangle())
    }
}

/// The 4-column metric strip container: one shared card with hairline separators.
struct HomeMetricsRow: View {
    let tiles: [(icon: String, label: String, value: String, color: Color, detail: HomeTileDetail)]
    let highlightedTitle: String?
    let onSelect: (HomeTileDetail) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(tiles.enumerated()), id: \.offset) { index, tile in
                HomeMetricTile(
                    icon: tile.icon,
                    label: tile.label,
                    value: tile.value,
                    color: tile.color,
                    isHighlighted: highlightedTitle == tile.detail.title
                )
                .onTapGesture { onSelect(tile.detail) }
                if index < tiles.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.08))
                        .frame(width: 1, height: 34)
                }
            }
        }
        .glassCard(opacity: 0.65)
    }
}

/// One cell of the device strip (Reservoir / Pod / Battery / CGM): its own small card.
struct HomeDeviceTile: View {
    let icon: String
    let label: String
    let value: String
    let color: Color
    let isHighlighted: Bool

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundStyle(color)
                Text(value)
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .kerning(0.5)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 46)
        .glassCard(radius: GlassDesign.tileRadius, opacity: isHighlighted ? 1.0 : 0.5)
        .overlay(
            RoundedRectangle(cornerRadius: GlassDesign.tileRadius)
                .stroke(isHighlighted ? Color.tabBar.opacity(0.6) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

/// Centered card overlay describing a pressed tile, with shortcut action rows.
/// Presented from HomeRootView above a scrim; tapping the scrim closes it.
struct HomeTileDetailCard: View {
    let detail: HomeTileDetail
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail.title)
                    .glassCaption()
                Text(detail.body)
                    .font(.subheadline)
                    .foregroundStyle(.primary.opacity(0.8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ForEach(detail.actions) { action in
                Divider().overlay(Color.primary.opacity(0.08))
                Button {
                    onClose()
                    action.action()
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: action.icon)
                            .font(.system(size: 17))
                            .foregroundStyle(Color.tabBar)
                            .frame(width: 24)
                        Text(action.name)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .glassCard(radius: 16)
        .shadow(color: .black.opacity(0.4), radius: 22, y: 10)
        .padding(.horizontal, 16)
        .transition(.scale(scale: 0.96).combined(with: .opacity))
    }
}
