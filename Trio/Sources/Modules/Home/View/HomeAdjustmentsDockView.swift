import CoreData
import SwiftUI

/// A preset chip shown in the adjustments dock (override or temp target preset).
struct HomeDockChip: Identifiable {
    let id: String
    let name: String
    let icon: String
    let color: Color
    let isActive: Bool
    let action: () -> Void
}

/// Bottom adjustments dock: grab handle, a caller-provided status row (active
/// adjustment / bolus progress / idle text) and a horizontally scrollable row of
/// preset chips. Tap or drag up opens the full adjustments sheet.
struct HomeAdjustmentsDock<StatusRow: View>: View {
    let chips: [HomeDockChip]
    let onOpen: () -> Void
    @ViewBuilder let statusRow: StatusRow

    @Environment(\.colorScheme) var colorScheme
    @State private var dragStartY: CGFloat?

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.primary.opacity(0.28))
                .frame(width: 38, height: 4)
                .padding(.top, 7)
                .padding(.bottom, 5)

            statusRow
                .padding(.horizontal, 16)
                .padding(.bottom, 8)

            if !chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(chips) { chip in
                            Button(action: chip.action) {
                                HStack(spacing: 7) {
                                    Image(systemName: chip.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(chip.color)
                                    Text(chip.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 38)
                                .background(
                                    chip.isActive
                                        ? Color.tabBar.opacity(0.22)
                                        : Color.chart.opacity(colorScheme == .dark ? 0.85 : 1)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: GlassDesign.tileRadius))
                                .overlay(
                                    RoundedRectangle(cornerRadius: GlassDesign.tileRadius)
                                        .stroke(
                                            chip.isActive ? chip.color : Color.primary.opacity(0.12),
                                            lineWidth: 1
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 10)
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                .fill(colorScheme == .dark ? Color.chart.opacity(0.6) : Color.chart)
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 20, topTrailingRadius: 20)
                        .stroke(Color.primary.opacity(0.1), lineWidth: 1)
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if dragStartY == nil { dragStartY = value.startLocation.y }
                    if value.translation.height < -34 {
                        dragStartY = nil
                        onOpen()
                    }
                }
                .onEnded { _ in dragStartY = nil }
        )
        .onTapGesture { onOpen() }
    }
}

/// Transient confirmation toast (preset started/cancelled) shown at the top of Home.
struct HomeToastView: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 17))
                .foregroundStyle(Color.loopGreen)
            Text(text)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 46)
        .glassCard(radius: 14)
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
