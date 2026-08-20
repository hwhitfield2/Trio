import Foundation
import LoopKit
import SwiftUI

/// The one-line answer to "what is this pump doing right now", ranked by what
/// would stop insulin first.
///
/// The pump screen's status card and Trio's home-screen status highlight are
/// the same question asked in two places. They read it from here rather than
/// each deciding for themselves, so the home screen cannot report a suspend
/// while the pump screen reports the unacknowledged alarm that caused it.
struct TandemHeadlineStatus {
    /// Short enough for the home screen, which lays the highlight out in a
    /// ~100pt column in footnote text.
    let title: String
    /// A sentence for the pump screen.
    let detail: String
    let tone: TandemTone
    let symbolName: String

    /// True when there is nothing the user needs to act on.
    var isNominal: Bool { tone == .ok }
}

/// One precondition of the current basal-control mode, and whether the pump
/// meets it right now.
struct TandemReadinessCheck: Identifiable {
    let text: String
    let isMet: Bool

    var id: String { text }
}

extension TandemPumpState {
    // MARK: - Sync freshness

    /// Trio's loop runs every five minutes and the poll skips anything newer
    /// than two, so six minutes is the first point at which a sync is late
    /// rather than simply recent. Twelve is where the driver has always called
    /// it signal loss, and that threshold is kept.
    static let syncAgingInterval: TimeInterval = .minutes(6)
    static let syncStaleInterval: TimeInterval = .minutes(12)

    var hasEverSynced: Bool { lastSync != .distantPast }

    var syncAge: TimeInterval? {
        guard hasEverSynced else { return nil }
        return Date.now.timeIntervalSince(lastSync)
    }

    var syncIsStale: Bool {
        guard let age = syncAge else { return false }
        return age > Self.syncStaleInterval
    }

    var syncTone: TandemTone {
        guard let age = syncAge else { return .caution }
        if age > Self.syncStaleInterval { return .critical }
        if age > Self.syncAgingInterval { return .caution }
        return .ok
    }

    /// Shared because these read on every redraw of a list row, and building a
    /// date formatter is not free.
    static let relativeDateFormatter = RelativeDateTimeFormatter()

    /// "2 minutes ago" / "Never".
    var lastSyncDescription: String {
        guard hasEverSynced else { return String(localized: "Never") }
        return Self.relativeDateFormatter.localizedString(for: lastSync, relativeTo: Date.now)
    }

    // MARK: - Reservoir

    var reservoirCapacity: Double { pumpModel.reservoirCapacity }

    /// 0…1 against this model's cartridge size, or nil before the first sync —
    /// a reservoir of zero units and a reservoir Trio has never read look
    /// identical in the raw value, and only one of them is an emergency.
    var reservoirFraction: Double? {
        guard hasEverSynced, reservoirCapacity > 0 else { return nil }
        return min(max(reservoir / reservoirCapacity, 0), 1)
    }

    /// The pump reports whole units and flags its own reading as an estimate,
    /// which is why a value shows as "42+ U".
    var reservoirDescription: String {
        guard hasEverSynced else { return "—" }
        let units = Int(reservoir)
        return reservoirIsEstimate
            ? String(localized: "\(units)+ U")
            : String(localized: "\(units) U")
    }

    var reservoirTone: TandemTone {
        guard hasEverSynced else { return .idle }
        if reservoir <= 0 { return .critical }
        if reservoir <= 15 { return .caution }
        return .info
    }

    var batteryDescription: String {
        guard let batteryPercent else { return "—" }
        return String(localized: "\(batteryPercent)%")
    }

    var batteryTone: TandemTone {
        guard let batteryPercent else { return .idle }
        if batteryPercent <= 10 { return .critical }
        if batteryPercent <= 25 { return .caution }
        return .info
    }

    // MARK: - Delivery

    /// What is delivering, short enough for a third-width tile. The long
    /// version of the same news is the headline's detail line.
    var deliveryDescription: String {
        if cartridgeChangeInProgress {
            return String(localized: "Stopped")
        }
        if suspended || microbolusSuspended {
            return String(localized: "Suspended")
        }
        guard hasEverSynced else { return "—" }
        if let temp = activeTempBasal, temp.isActive() {
            return String(localized: "\(Self.rateText(temp.unitsPerHour)) U/hr")
        }
        return String(localized: "\(Self.rateText(currentBasalRate)) U/hr")
    }

    /// Caption under the delivery tile, naming what is unusual about it.
    var deliveryCaption: String? {
        if cartridgeChangeInProgress { return String(localized: "cartridge change") }
        if let temp = activeTempBasal, temp.isActive() { return String(localized: "temp rate") }
        return nil
    }

    var deliveryTone: TandemTone {
        if cartridgeChangeInProgress { return .caution }
        if suspended || microbolusSuspended { return .caution }
        guard hasEverSynced else { return .idle }
        return .info
    }

    /// Rates and insulin amounts go through locale-aware formatters: a decimal
    /// point is not the separator everywhere, and `String(format:)` always
    /// writes one.
    static let rateFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    static let milliunitFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = 3
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static func rateText(_ unitsPerHour: Double) -> String {
        rateFormatter.string(from: NSNumber(value: unitsPerHour)) ?? String(format: "%.2f", unitsPerHour)
    }

    static func unitsText(_ units: Double) -> String {
        milliunitFormatter.string(from: NSNumber(value: units)) ?? String(format: "%.3f", units)
    }

    /// A dose written as short as it is exact: 0.05, 0.051, 0.2. Used for the
    /// fixed lists of amounts the screens offer.
    static let doseFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = .current
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 3
        return formatter
    }()

    static func doseText(_ units: Double) -> String {
        doseFormatter.string(from: NSNumber(value: units)) ?? String(format: "%g", units)
    }

    // MARK: - Basal control readiness

    /// The preconditions the active basal-control mode needs, each with whether
    /// the pump currently meets it.
    ///
    /// These are the same conditions the driver enforces before every command;
    /// showing them as a checklist is what turns "Trio refused to set a temp
    /// basal" into "Control-IQ is on".
    var basalControlChecks: [TandemReadinessCheck] {
        switch basalControlMode {
        case .none:
            return []
        case .nativeTempRate:
            return [
                TandemReadinessCheck(
                    // Worded as a reading rather than a fact: the Control-IQ
                    // query is allowed to fail without failing the whole sync,
                    // so this is what the pump last said, not what it is doing
                    // this second. The driver re-reads it before every command.
                    text: String(localized: "The pump reported Control-IQ off"),
                    isMet: !controlIQEnabled
                ),
                TandemReadinessCheck(
                    text: String(
                        localized: "The pump's basal profile is not zero (currently \(Self.rateText(profileBasalRate)) U/hr)"
                    ),
                    isMet: profileBasalRate >= TandemPumpManager.minimumProfileBasalForTempRate
                ),
                TandemReadinessCheck(
                    text: String(localized: "Insulin is not suspended on the pump"),
                    isMet: !suspended
                ),
                TandemReadinessCheck(
                    text: String(localized: "Trio has read the pump in the last 10 minutes"),
                    isMet: isWithin(TandemPumpManager.tempBasalContextMaxStaleness)
                )
            ]
        case .microbolus:
            return [
                TandemReadinessCheck(
                    text: String(localized: "The pump reported Control-IQ off"),
                    isMet: !controlIQEnabled
                ),
                TandemReadinessCheck(
                    text: String(
                        localized: "The pump's own basal profile is zeroed — at or below \(Self.rateText(TandemPumpManager.basalPreconditionEpsilonUnitsPerHour)) U/hr (currently \(Self.rateText(profileBasalRate)) U/hr)"
                    ),
                    isMet: profileBasalRate <= TandemPumpManager.basalPreconditionEpsilonUnitsPerHour
                ),
                TandemReadinessCheck(
                    text: String(localized: "Trio is not holding basal delivery"),
                    isMet: !microbolusSuspended
                ),
                TandemReadinessCheck(
                    text: String(localized: "Trio has read the pump in the last 10 minutes"),
                    isMet: isWithin(TandemPumpManager.preconditionMaxStaleness)
                )
            ]
        }
    }

    /// The driver refuses a basal command against a status older than its own
    /// staleness window, so the checklist asks the same question with the same
    /// constant rather than inventing a second definition of "recent".
    private func isWithin(_ window: TimeInterval) -> Bool {
        guard hasEverSynced else { return false }
        return Date.now.timeIntervalSince(lastSync) < window
    }

    var basalControlIsReady: Bool {
        basalControlMode != .none && basalControlChecks.allSatisfy(\.isMet)
    }

    /// How much of the pump's profile rate Trio can reach with a temp rate.
    /// Tandem temp rates are a whole percentage of the profile, capped at 250%,
    /// which surprises people who expect to be able to ask for any rate.
    var maximumTempRate: Double? {
        guard supportsNativeBasalControl,
              profileBasalRate >= TandemPumpManager.minimumProfileBasalForTempRate
        else { return nil }
        return profileBasalRate * Double(TandemTempRateLimits.maxPercent) / 100
    }

    // MARK: - Headline

    /// Ranked worst-first, because that is the order the user needs: an
    /// alarming pump has already stopped insulin, and everything below it is a
    /// consequence rather than a separate problem.
    var headlineStatus: TandemHeadlineStatus {
        if pairingCode.isEmpty {
            return TandemHeadlineStatus(
                title: String(localized: "Not Paired"),
                detail: String(localized: "No pump is paired with Trio."),
                tone: .critical,
                symbolName: "exclamationmark.circle.fill"
            )
        }
        if let alarms = activeAlarmNames {
            return TandemHeadlineStatus(
                title: String(localized: "Pump Alarm"),
                detail: String(
                    localized: "The pump is alarming: \(alarms). It has stopped insulin and will refuse new commands until the alarm is acknowledged."
                ),
                tone: .critical,
                symbolName: "bell.badge.fill"
            )
        }
        if cartridgeChangeInProgress {
            return TandemHeadlineStatus(
                title: String(localized: "Changing Cartridge"),
                detail: String(
                    localized: "A cartridge change is open. Insulin is stopped and Trio will not loop until it is finished or cancelled."
                ),
                tone: .caution,
                symbolName: "arrow.triangle.2.circlepath"
            )
        }
        if microbolusSuspended {
            return TandemHeadlineStatus(
                title: String(localized: "Insulin Suspended"),
                detail: String(localized: "Trio is holding basal delivery."),
                tone: .caution,
                symbolName: "pause.circle.fill"
            )
        }
        if suspended {
            return TandemHeadlineStatus(
                title: String(localized: "Insulin Suspended"),
                detail: pumpModel == .mobi
                    ? String(localized: "The pump is not delivering. Resume it in Trio.")
                    : String(localized: "The pump is not delivering. Restart it on the pump."),
                tone: .caution,
                symbolName: "pause.circle.fill"
            )
        }
        if !hasEverSynced {
            return TandemHeadlineStatus(
                title: String(localized: "No Pump Data"),
                detail: String(localized: "Trio has not read anything from this pump yet."),
                tone: .caution,
                symbolName: "antenna.radiowaves.left.and.right.slash"
            )
        }
        if syncIsStale {
            return TandemHeadlineStatus(
                title: String(localized: "Signal Loss"),
                detail: String(
                    localized: "Trio has not heard from the pump since \(lastSyncDescription). Keep the phone near the pump."
                ),
                tone: .critical,
                symbolName: "antenna.radiowaves.left.and.right.slash"
            )
        }
        if reservoir <= 0 {
            return TandemHeadlineStatus(
                title: String(localized: "Cartridge Empty"),
                detail: String(localized: "The pump reports no insulin left."),
                tone: .critical,
                symbolName: "drop.triangle.fill"
            )
        }
        // A mode is chosen but the pump does not currently satisfy it: Trio is
        // not looping, and saying "Ready" with a green tick would be the most
        // misleading thing this screen could do.
        if basalControlMode != .none, !basalControlIsReady {
            return TandemHeadlineStatus(
                title: String(localized: "Not Looping"),
                detail: basalControlMode == .microbolus
                    ? String(localized: "Trio cannot deliver basal until the conditions below are met.")
                    : String(localized: "Trio cannot set temp rates until the conditions below are met."),
                tone: .caution,
                symbolName: "exclamationmark.triangle.fill"
            )
        }
        // Nothing is wrong, but nobody asked Trio to close the loop either.
        // That is a choice, not a fault, so it never becomes a home-screen
        // warning — `.info` maps to no highlight at all.
        if basalControlMode == .none {
            return TandemHeadlineStatus(
                title: String(localized: "Monitoring"),
                detail: supportsNativeBasalControl
                    ? String(localized: "The pump is managing basal on its own, so Trio is not looping.")
                    : String(localized: "The pump is managing basal on its own. Trio is monitoring it."),
                tone: .info,
                symbolName: "eye"
            )
        }
        return TandemHeadlineStatus(
            title: String(localized: "Looping"),
            detail: basalControlMode == .microbolus
                ? String(localized: "Trio is delivering basal as microboluses.")
                : String(localized: "Trio is setting temp rates on the pump."),
            tone: .ok,
            symbolName: "checkmark.circle.fill"
        )
    }
}
