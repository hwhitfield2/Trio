import SwiftUI
import UIKit

/// Shared visual language for the Tandem screens.
///
/// These screens are hosted in their own `UIHostingController` from
/// `TandemUICoordinator`, so unlike the rest of Trio they cannot read `AppState`
/// out of the SwiftUI environment. The background therefore comes from a local
/// instance rather than being duplicated, so the Tandem screens keep matching
/// the app when the app's own background changes.
enum TandemTheme {
    private static let appState = AppState()

    static func background(for colorScheme: ColorScheme) -> LinearGradient {
        appState.trioBackgroundColor(for: colorScheme)
    }
}

/// How serious something on a Tandem screen is.
///
/// Every tone pairs a colour with a symbol and is always used alongside words,
/// so nothing on these screens is signalled by colour alone — which matters
/// here more than usual, because for a Mobi user this is the pump's only
/// display.
enum TandemTone {
    /// Working as intended.
    case ok
    /// Neutral information.
    case info
    /// Needs attention but is not stopping insulin.
    case caution
    /// Insulin is stopped or unsafe to rely on.
    case critical
    /// Not applicable right now.
    case idle

    var color: Color {
        switch self {
        case .ok: return .loopGreen
        case .info: return .insulin
        case .caution: return .warning
        case .critical: return .loopRed
        case .idle: return .secondary
        }
    }

    var symbolName: String {
        switch self {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle.fill"
        case .caution: return "exclamationmark.triangle.fill"
        case .critical: return "exclamationmark.octagon.fill"
        case .idle: return "circle.dashed"
        }
    }
}

// MARK: - Screen chrome

private struct TandemScreenBackground: ViewModifier {
    @Environment(\.colorScheme) var colorScheme

    func body(content: Content) -> some View {
        content
            .listSectionSpacing(sectionSpacing)
            .scrollContentBackground(.hidden)
            .background(TandemTheme.background(for: colorScheme))
    }
}

extension View {
    /// Trio's list treatment: sections floating on the app gradient.
    func tandemScreenBackground() -> some View {
        modifier(TandemScreenBackground())
    }

    /// Trio's card surface for a list row.
    func tandemRowBackground() -> some View {
        listRowBackground(Color.chart)
    }
}

// MARK: - Status pill

/// A compact "here is the one-word state" marker: connection, sync freshness,
/// whether a mode is on.
struct TandemStatusPill: View {
    let text: String
    var tone: TandemTone = .info
    var symbolName: String?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbolName ?? tone.symbolName)
                .imageScale(.small)
            Text(text)
                .font(.caption)
                .fontWeight(.semibold)
        }
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Callout

/// A block that names a situation, explains it in a sentence, and — when there
/// is one — offers the action that resolves it.
///
/// This replaces the bare red `.footnote` these screens used to end every
/// failure with: an error the user cannot act on is only half an error message.
struct TandemCallout<Action: View>: View {
    private let title: String
    private let message: String
    private let tone: TandemTone
    private let symbolName: String?
    private let action: Action

    init(
        title: String,
        message: String,
        tone: TandemTone = .caution,
        symbolName: String? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.title = title
        self.message = message
        self.tone = tone
        self.symbolName = symbolName
        self.action = action()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: symbolName ?? tone.symbolName)
                    .foregroundStyle(tone.color)
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
            }
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            action
        }
        .padding(.vertical, 2)
    }
}

extension TandemCallout where Action == EmptyView {
    init(
        title: String,
        message: String,
        tone: TandemTone = .caution,
        symbolName: String? = nil
    ) {
        self.init(title: title, message: message, tone: tone, symbolName: symbolName) { EmptyView() }
    }
}

// MARK: - Metric tile

/// One number with its label, for the status card at the top of the pump screen.
struct TandemMetricTile: View {
    let label: String
    let value: String
    var caption: String?
    var systemImage: String
    var tone: TandemTone = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                Text(label)
                    .glassCaption()
            }
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundStyle(tone == .idle ? Color.primary : tone.color)
            if let caption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(caption.map { "\(label): \(value), \($0)" } ?? "\(label): \(value)")
    }
}

// MARK: - Bars

/// How full the cartridge is, against this model's capacity.
struct TandemLevelBar: View {
    /// 0…1. Values outside that range are clamped.
    let fraction: Double
    var tone: TandemTone = .info

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(tone.color)
                    .frame(width: max(2, geometry.size.width * clamped))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    private var clamped: Double {
        guard fraction.isFinite else { return 0 }
        return min(max(fraction, 0), 1)
    }
}

// MARK: - Rows

/// Label/value row that stacks instead of truncating at large Dynamic Type, and
/// reads as one element to VoiceOver.
struct TandemInfoRow: View {
    let label: String
    let value: String
    var tone: TandemTone?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(label)
                Spacer(minLength: 12)
                valueText
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                valueText
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private var valueText: some View {
        Text(value)
            .foregroundStyle(tone?.color ?? Color.secondary)
    }
}

/// One precondition and whether the pump currently meets it.
struct TandemChecklistRow: View {
    let text: String
    let isMet: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isMet ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(isMet ? Color.loopGreen : Color.warning)
            Text(text)
                .font(.footnote)
                .foregroundStyle(isMet ? Color.secondary : Color.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isMet
                ? String(localized: "Met: \(text)")
                : String(localized: "Not met: \(text)")
        )
    }
}

// MARK: - Buttons

/// The screens' one button shape.
///
/// It keeps its title while it is busy instead of swapping the label for a
/// spinner — on these screens a button's label is often the only record of what
/// the user just asked the pump to do, and a change takes several seconds.
struct TandemActionButton: View {
    enum Emphasis {
        case prominent
        case bordered
        case destructive
    }

    let title: String
    var systemImage: String?
    var emphasis: Emphasis = .prominent
    var isBusy: Bool = false
    var busyTitle: String?
    let action: () -> Void

    var body: some View {
        switch emphasis {
        case .prominent:
            button.buttonStyle(.borderedProminent).tint(Color.insulin)
        case .bordered:
            button.buttonStyle(.bordered).tint(Color.insulin)
        case .destructive:
            button.buttonStyle(.bordered).tint(Color.loopRed)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                } else if let systemImage {
                    Image(systemName: systemImage)
                }
                Text(isBusy ? (busyTitle ?? title) : title)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity, minHeight: 24)
        }
        .disabled(isBusy)
    }
}

// MARK: - Step rail

/// Where the user is in a multi-step procedure.
///
/// A cartridge change is a sequence of physical acts with insulin stopped
/// throughout; "which step am I on and how many are left" is the question the
/// screen has to answer before anything else.
struct TandemStepRail: View {
    let titles: [String]
    let currentIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(titles.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= currentIndex ? Color.insulin : Color.primary.opacity(0.15))
                        .frame(height: 4)
                }
            }
            Text(caption)
                .font(.footnote)
                .fontWeight(.semibold)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
    }

    private var caption: String {
        guard titles.indices.contains(currentIndex) else {
            return String(localized: "Not started")
        }
        return String(localized: "Step \(currentIndex + 1) of \(titles.count): \(titles[currentIndex])")
    }
}

// MARK: - Haptics

/// Confirmation the user can feel.
///
/// These screens send commands over Bluetooth that take a moment and often
/// happen while the phone is not being looked at — during a cartridge change
/// the user's hands are on the pump.
enum TandemHaptics {
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }

    static func failure() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
}
