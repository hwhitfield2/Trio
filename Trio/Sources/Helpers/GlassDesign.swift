import SwiftUI

/// Shared visual language for the glass redesign (derived from the "Trio Prototype" design).
/// All colors route through the existing asset-backed palette in Color+Extensions.swift;
/// the two additions below are prototype accents that have no asset yet.
enum GlassDesign {
    static let cardRadius: CGFloat = 14
    static let tileRadius: CGFloat = 12

    /// Cyan → indigo → purple accent gradient (hero accent bar, emphasis art).
    /// Matches the purple→cyan gradient already used by BolusProgressBar/CustomProgressView.
    static let accentGradient = LinearGradient(
        colors: [Color.glassCyan, Color.tabBar, Color.uam],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Color {
    /// #43BBE9 — prototype accent cyan (same hue as the TrendShape triangle / progress gradient end).
    static let glassCyan = Color(red: 0.263, green: 0.733, blue: 0.914)
}

extension Notification.Name {
    /// Posted by the Home quick-actions menu to ask the History tab to present its
    /// manual glucose entry sheet.
    static let presentManualGlucoseEntry = Notification.Name("TrioPresentManualGlucoseEntry")
}

/// Card surface used across the redesigned screens: Chart-colored surface with a hairline border.
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) var colorScheme
    var radius: CGFloat = GlassDesign.cardRadius
    var opacity: Double = 1.0

    func body(content: Content) -> some View {
        content
            .background(Color.chart.opacity(colorScheme == .dark ? opacity * 0.85 : 1))
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(Color.primary.opacity(colorScheme == .dark ? 0.09 : 0.06), lineWidth: 1)
            )
    }
}

/// Small uppercase tracking caption used for tile and section labels.
struct GlassCaption: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 10, weight: .medium))
            .kerning(0.7)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
    }
}

extension View {
    func glassCard(radius: CGFloat = GlassDesign.cardRadius, opacity: Double = 1.0) -> some View {
        modifier(GlassCard(radius: radius, opacity: opacity))
    }

    func glassCaption() -> some View {
        modifier(GlassCaption())
    }
}
