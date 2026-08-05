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

/// A pending stop request inside the dock preset sheet.
enum HomeDockStopTarget: Identifiable {
    case override(String)
    case tempTarget(String)

    var id: String { name }

    var name: String {
        switch self {
        case let .override(name),
             let .tempTarget(name):
            return name
        }
    }

    var isOverride: Bool {
        if case .override = self { return true }
        return false
    }
}

/// Compact preset sheet opened by dragging/tapping the dock (from the prototype):
/// Overrides|Temp Targets segmented control, preset cards with Start/End, and a
/// dashed custom row. Backed by the caller's live fetch results and the same
/// enact/cancel paths the dock chips use — no extra state model per presentation.
struct HomeAdjustmentsSheetView: View {
    let overridePresets: [OverrideStored]
    let tempTargetPresets: [TempTargetStored]
    let units: GlucoseUnits
    let requireConfirmation: Bool
    let activate: (DockChipActivation) -> Void
    let cancelOverride: () -> Void
    let cancelTempTarget: () -> Void
    let onManage: () -> Void

    @State private var tab: Adjustments.Tab = .overrides
    @State private var pendingActivation: DockChipActivation?
    @State private var pendingStop: HomeDockStopTarget?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Adjustments")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                    onManage()
                } label: {
                    HStack(spacing: 4) {
                        Text("Manage")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .font(.subheadline)
                    .foregroundStyle(Color.tabBar)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 12)

            Picker("Adjustment Type", selection: $tab) {
                ForEach(Adjustments.Tab.allCases) { tab in
                    Text(tab.name).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            ScrollView {
                VStack(spacing: 8) {
                    if tab == .overrides {
                        ForEach(overridePresets, id: \.objectID) { preset in
                            presetCard(
                                name: preset.name ?? String(localized: "Custom Override"),
                                detail: overrideDetail(for: preset),
                                icon: "clock.arrow.2.circlepath",
                                color: .purple,
                                isActive: preset.enabled,
                                objectID: preset.objectID,
                                isOverride: true
                            )
                        }
                        if overridePresets.isEmpty {
                            emptyHint(String(localized: "No override presets yet."))
                        }
                        customRow(String(localized: "Custom override…"))
                    } else {
                        ForEach(tempTargetPresets, id: \.objectID) { preset in
                            presetCard(
                                name: preset.name ?? String(localized: "Temp Target"),
                                detail: tempTargetDetail(for: preset),
                                icon: "target",
                                color: .loopGreen,
                                isActive: preset.enabled,
                                objectID: preset.objectID,
                                isOverride: false
                            )
                        }
                        if tempTargetPresets.isEmpty {
                            emptyHint(String(localized: "No temp target presets yet."))
                        }
                        customRow(String(localized: "Custom temp target…"))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
        }
        .background(appState.trioBackgroundColor(for: colorScheme))
        .confirmationDialog(
            pendingActivation.map {
                $0.isOverride
                    ? String(localized: "Start the Override \"\($0.name)\"?")
                    : String(localized: "Start the Temp Target \"\($0.name)\"?")
            } ?? "",
            isPresented: Binding(
                get: { pendingActivation != nil },
                set: { if !$0 { pendingActivation = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingActivation
        ) { activation in
            Button("Start") { activate(activation) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            pendingStop.map {
                $0.isOverride
                    ? String(localized: "Stop the Override \"\($0.name)\"?")
                    : String(localized: "Stop the Temp Target \"\($0.name)\"?")
            } ?? "",
            isPresented: Binding(
                get: { pendingStop != nil },
                set: { if !$0 { pendingStop = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingStop
        ) { stop in
            Button("Stop", role: .destructive) {
                if stop.isOverride { cancelOverride() } else { cancelTempTarget() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func overrideDetail(for preset: OverrideStored) -> String {
        var parts = [String]()
        if preset.indefinite {
            parts.append(String(localized: "Indefinite"))
        } else if let duration = preset.duration, duration.doubleValue > 0 {
            parts.append(formatHrMin(Int(truncating: duration)))
        }
        if preset.percentage != 100 {
            parts.append("\(preset.percentage.formatted(.number)) %")
        }
        if let target = preset.target, target.decimalValue != 0 {
            let display = units == .mmolL
                ? target.decimalValue.formattedAsMmolL
                : (Formatter.integerFormatter.string(from: target) ?? "")
            parts.append(display + " " + units.rawValue)
        }
        return parts.joined(separator: " · ")
    }

    private func tempTargetDetail(for preset: TempTargetStored) -> String {
        var parts = [String]()
        if let target = preset.target, target.decimalValue != 0 {
            let display = units == .mmolL
                ? target.decimalValue.formattedAsMmolL
                : (Formatter.integerFormatter.string(from: target) ?? "")
            parts.append(display + " " + units.rawValue)
        }
        if let duration = preset.duration, duration.doubleValue > 0 {
            parts.append(String(localized: "for \(Int(truncating: duration)) min"))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func presetCard(
        name: String,
        detail: String,
        icon: String,
        color: Color,
        isActive: Bool,
        objectID: NSManagedObjectID,
        isOverride: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(color)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            Button {
                if isActive {
                    pendingStop = isOverride ? .override(name) : .tempTarget(name)
                } else if requireConfirmation {
                    pendingActivation = DockChipActivation(name: name, isOverride: isOverride, objectID: objectID)
                } else {
                    activate(DockChipActivation(name: name, isOverride: isOverride, objectID: objectID))
                }
            } label: {
                Text(isActive ? String(localized: "End") : String(localized: "Start"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isActive ? Color.white : Color.primary)
                    .padding(.horizontal, 14)
                    .frame(height: 34)
                    .background(
                        isActive
                            ? Color.loopRed.opacity(0.85)
                            : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.06)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 11))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .glassCard()
        .overlay(
            RoundedRectangle(cornerRadius: GlassDesign.cardRadius)
                .stroke(isActive ? color.opacity(0.6) : Color.clear, lineWidth: 1)
        )
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
    }

    private func customRow(_ label: String) -> some View {
        Button {
            dismiss()
            onManage()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 16, weight: .semibold))
                Text(label)
                    .font(.system(size: 15))
            }
            .foregroundStyle(Color.tabBar)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .overlay(
                RoundedRectangle(cornerRadius: GlassDesign.tileRadius)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Color.primary.opacity(0.25))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
