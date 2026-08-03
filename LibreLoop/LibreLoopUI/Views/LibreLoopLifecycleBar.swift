import SwiftUI
import LibreLoop

struct LibreLoopLifecycleBar: View {
    let lifecycle: LibreLoopSensorLifecycle
    /// Optional protocol-level detail (Authenticating / Refreshing
    /// notifications / Waiting for first reading). Surfaced as the
    /// lifecycle bar's secondary line during the Initializing phase.
    var statusDetail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(lifecycle.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stateColor)
                Spacer()
                Text(secondaryText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(.quaternary)
                    Capsule()
                        .fill(stateColor)
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 8)
        }
    }

    private var progress: Double {
        switch lifecycle {
        case .noSensor, .initializing, .pairingWarmup: return 0
        case .warmup(let p, _): return p
        case .active(let remaining, let total):
            return (total - remaining) / total
        case .expired: return 1
        case .signalLost: return 0
        case .failed: return 1
        }
    }

    private var stateColor: Color {
        switch lifecycle {
        case .noSensor:       return .gray
        case .initializing:   return .yellow
        case .warmup:         return .orange
        case .pairingWarmup:  return .orange
        case .active:         return .green
        case .expired:        return .red
        case .signalLost:     return .yellow
        case .failed:         return .red
        }
    }

    private var secondaryText: String {
        switch lifecycle {
        case .noSensor:
            return ""
        case .initializing:
            return statusDetail ?? LocalizedString("Waiting for first reading", comment: "Lifecycle bar detail: waiting for first reading")
        case .warmup(_, let remaining):
            return String(format: LocalizedString("%@ until ready", comment: "Lifecycle bar detail: warmup time remaining"), formatRemaining(remaining))
        case .pairingWarmup:
            // Brief window between BLE pair complete and the first
            // realtime frame arriving (~minute or less). Any reading
            // ends this state -- the actionability flag is surfaced
            // per-sample via isDisplayOnly, not held against the
            // lifecycle.
            return LocalizedString("Awaiting first reading", comment: "Lifecycle bar detail: awaiting first reading after pairing")
        case .active(let remaining, _):
            return String(format: LocalizedString("%@ remaining", comment: "Lifecycle bar detail: active time remaining"), formatRemaining(remaining))
        case .expired:
            return LocalizedString("Replace sensor", comment: "Lifecycle bar detail: replace sensor")
        case .signalLost(let since):
            return String(format: LocalizedString("Last reading %@", comment: "Lifecycle bar detail: time since last reading"), Self.relativeFormatter.localizedString(for: since, relativeTo: Date()))
        case .failed:
            return LocalizedString("Replace sensor", comment: "Lifecycle bar detail: replace sensor")
        }
    }

    private func formatElapsed(_ seconds: TimeInterval) -> String {
        let hours = Int(seconds / 3_600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60)
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        if minutes >= 1 { return "\(minutes)m" }
        return "\(Int(seconds))s"
    }

    private func formatRemaining(_ seconds: TimeInterval) -> String {
        let days = Int(seconds / 86_400)
        let hours = Int((seconds.truncatingRemainder(dividingBy: 86_400)) / 3_600)
        let minutes = Int((seconds.truncatingRemainder(dividingBy: 3_600)) / 60)
        if days >= 1 { return "\(days)d \(hours)h" }
        if hours >= 1 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()
}
