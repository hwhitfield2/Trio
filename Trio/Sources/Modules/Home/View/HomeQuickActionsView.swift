import SwiftUI

/// One entry of the quick actions menu on the + tab button.
struct HomeQuickAction: Identifiable {
    let id = UUID()
    let name: String
    let icon: String
    let color: Color
    var hint: String = ""
    let action: () -> Void
}

/// The quick actions card that pops above the tab bar on a tap of +.
/// A long press on + skips this and opens the full Treatments editor.
struct HomeQuickActionsCard: View {
    let actions: [HomeQuickAction]
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(actions.enumerated()), id: \.element.id) { index, item in
                if index > 0 {
                    Divider().overlay(Color.primary.opacity(0.09))
                }
                Button {
                    onClose()
                    item.action()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: item.icon)
                            .font(.system(size: 19))
                            .foregroundStyle(item.color)
                            .frame(width: 26)
                        Text(item.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                        Spacer()
                        if !item.hint.isEmpty {
                            Text(item.hint)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 274)
        .glassCard(radius: 16)
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
        .transition(.scale(scale: 0.95, anchor: .bottom).combined(with: .opacity))
    }
}
