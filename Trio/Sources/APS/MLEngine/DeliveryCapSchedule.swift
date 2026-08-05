import Foundation

/// Scheduled insulin-delivery caps (docs/ML_DOSING_REPLACEMENT_PLAN.md §2.4).
///
/// A window caps what the loop may *deliver* during a time of day — down to
/// zero — while the loop itself keeps running every cycle: determinations,
/// forecasts, and audit records are produced as always, and only enactment is
/// clamped. With `maxBasalRate == 0 && maxSMB == 0` the window means
/// "no insulin from the loop in this period": SMBs are suppressed and a
/// zero-temp overrides scheduled basal for the duration of the window.
///
/// Manual boluses are intentionally NOT affected: the caps constrain the loop,
/// not the user.
struct DeliveryCapWindow: JSON, Equatable, Identifiable {
    var id = UUID()
    /// Minutes since local midnight, 0...1439. A window may wrap midnight
    /// (end <= start, e.g. 22:00–06:00). start == end means the full day.
    var startMinutes: Int
    var endMinutes: Int
    /// Ceiling for loop basal delivery during the window (U/hr). 0 = zero-temp.
    var maxBasalRate: Decimal
    /// Ceiling per SMB during the window (U). 0 = no SMBs.
    var maxSMB: Decimal
}

enum DeliveryCaps {
    struct ActiveCap: Equatable {
        let maxBasalRate: Decimal
        let maxSMB: Decimal
    }

    struct ResolvedEnactment: Equatable {
        let rate: Decimal?
        let durationSeconds: TimeInterval?
        let smb: Decimal?
        let notes: [String]
    }

    static func minutesOfDay(for date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    static func isActive(_ window: DeliveryCapWindow, atMinuteOfDay minute: Int) -> Bool {
        if window.startMinutes == window.endMinutes {
            return true // full-day window
        }
        if window.startMinutes < window.endMinutes {
            return minute >= window.startMinutes && minute < window.endMinutes
        }
        // Wraps midnight, e.g. 22:00–06:00.
        return minute >= window.startMinutes || minute < window.endMinutes
    }

    /// The cap in force at `date`, or nil when no window matches. Overlapping
    /// windows combine to the most restrictive value per component.
    static func activeCap(
        in windows: [DeliveryCapWindow],
        at date: Date,
        calendar: Calendar = .current
    ) -> ActiveCap? {
        let minute = minutesOfDay(for: date, calendar: calendar)
        let matching = windows.filter { isActive($0, atMinuteOfDay: minute) }
        guard let first = matching.first else { return nil }
        return matching.dropFirst().reduce(
            ActiveCap(maxBasalRate: first.maxBasalRate, maxSMB: first.maxSMB)
        ) { cap, window in
            ActiveCap(
                maxBasalRate: min(cap.maxBasalRate, window.maxBasalRate),
                maxSMB: min(cap.maxSMB, window.maxSMB)
            )
        }
    }

    /// Scheduled basal rate at `date` from (minutes-of-day, rate) profile entries.
    static func scheduledRate(
        from entries: [(minutes: Int, rate: Decimal)],
        at date: Date,
        calendar: Calendar = .current
    ) -> Decimal {
        guard !entries.isEmpty else { return 0 }
        let sorted = entries.sorted { $0.minutes < $1.minutes }
        let minute = minutesOfDay(for: date, calendar: calendar)
        // Rate of the last entry starting at or before now; before the first
        // entry of the day the last entry of the previous day applies.
        return sorted.last(where: { $0.minutes <= minute })?.rate ?? sorted.last!.rate
    }

    /// Applies the cap to what the loop is about to enact.
    ///
    /// - `determinationRate/DurationSeconds`: the temp the algorithm wants
    ///   (nil = no temp change requested this cycle).
    /// - `smb`: the micro-bolus the algorithm wants (nil or 0 = none).
    /// - `effectiveUncappedRate`: what basal delivery would be with no action —
    ///   the running temp if one is active, else the scheduled profile rate.
    ///   Needed because a cap below current delivery must actively issue a
    ///   capped temp even when the algorithm requested no change.
    static func resolveEnactment(
        cap: ActiveCap,
        determinationRate: Decimal?,
        determinationDurationSeconds: TimeInterval?,
        smb: Decimal?,
        effectiveUncappedRate: Decimal
    ) -> ResolvedEnactment {
        var notes: [String] = []
        let enforcementDuration: TimeInterval = 30 * 60

        var rate = determinationRate
        var duration = determinationDurationSeconds
        if let requested = determinationRate {
            if requested > cap.maxBasalRate {
                rate = cap.maxBasalRate
                duration = determinationDurationSeconds ?? enforcementDuration
                notes.append("rate \(requested) → \(cap.maxBasalRate) U/hr (scheduled delivery cap)")
            }
        } else if effectiveUncappedRate > cap.maxBasalRate {
            // No temp requested, but current/scheduled delivery exceeds the cap:
            // actively issue a capped temp so the ceiling holds.
            rate = cap.maxBasalRate
            duration = enforcementDuration
            notes.append("enforcing \(cap.maxBasalRate) U/hr over \(effectiveUncappedRate) U/hr (scheduled delivery cap)")
        }

        var cappedSMB = smb
        if let requestedSMB = smb, requestedSMB > cap.maxSMB {
            cappedSMB = cap.maxSMB
            notes.append("SMB \(requestedSMB) → \(cap.maxSMB) U (scheduled delivery cap)")
        }

        return ResolvedEnactment(rate: rate, durationSeconds: duration, smb: cappedSMB, notes: notes)
    }
}
