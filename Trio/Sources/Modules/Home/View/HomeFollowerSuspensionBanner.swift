import SwiftUI

/// The in-app face of a follower's emergency stop.
///
/// The alarm this answers is a notification, and a notification is easy to
/// swipe away and then gone — leaving insulin stopped, the app saying nothing
/// about it, and the two answers reachable only from a settings screen nobody
/// would think to open. So the same two answers live here, on the Home screen,
/// for as long as the suspension goes unanswered.
///
/// Deliberately not a scrim-and-modal: someone deciding whether to restart
/// their insulin needs to see the glucose behind this, and trapping them behind
/// the decision would hide exactly the number the decision turns on.
struct HomeFollowerSuspensionBanner: View {
    let suspension: FollowerSuspension
    /// Re-rendered from the Home timer so the elapsed time keeps counting.
    let now: Date
    let onAcknowledge: (_ resumeDelivery: Bool) -> Void

    private var stoppedAtText: String {
        suspension.requestedAt.formatted(date: .omitted, time: .shortened)
    }

    /// "12 min", "1 hr 5 min" — how long insulin has been off. Rounded down to
    /// the minute, and never negative if the clock moved.
    private var elapsedText: String {
        let minutes = max(0, Int(now.timeIntervalSince(suspension.requestedAt) / 60))
        if minutes < 60 {
            return String(
                format: String(localized: "%d min", comment: "Minutes since insulin was suspended"),
                minutes
            )
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return String(
            format: String(localized: "%d hr %d min", comment: "Hours and minutes since insulin was suspended"),
            hours,
            remainder
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.loopRed)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Insulin suspended")
                        .font(.headline)
                    Text(
                        String(
                            format: String(
                                localized: "%1$@ stopped your insulin at %2$@ · %3$@ ago",
                                comment: "Who suspended insulin, when, and how long ago"
                            ),
                            suspension.followerName,
                            stoppedAtText,
                            elapsedText
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text("Delivery stays stopped until you answer, and this phone keeps alarming until then.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button {
                    onAcknowledge(true)
                } label: {
                    Text("I'm OK — resume insulin")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .background(Color.loopRed)
                        .clipShape(RoundedRectangle(cornerRadius: GlassDesign.tileRadius))
                }
                .buttonStyle(.plain)

                Button {
                    onAcknowledge(false)
                } label: {
                    Text("I'm OK — stay suspended")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                        .glassCard(radius: GlassDesign.tileRadius, opacity: 0.7)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .glassCard(radius: 16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.loopRed.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}
