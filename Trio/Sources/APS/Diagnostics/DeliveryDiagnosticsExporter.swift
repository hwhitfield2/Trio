import CoreData
import Foundation
import Swinject

/// How far back an export reaches.
enum DeliveryDiagnosticsWindow: String, CaseIterable, Identifiable {
    case sixHours
    case twentyFourHours
    case sevenDays

    var id: String { rawValue }

    var duration: TimeInterval {
        switch self {
        case .sixHours: return 6 * 60 * 60
        case .twentyFourHours: return 24 * 60 * 60
        case .sevenDays: return 7 * 24 * 60 * 60
        }
    }

    /// Short tag used in the file name.
    var fileLabel: String {
        switch self {
        case .sixHours: return "6h"
        case .twentyFourHours: return "24h"
        case .sevenDays: return "7d"
        }
    }

    var displayName: String {
        switch self {
        case .sixHours: return String(localized: "6 hours", comment: "Delivery diagnostics export window")
        case .twentyFourHours: return String(localized: "24 hours", comment: "Delivery diagnostics export window")
        case .sevenDays: return String(localized: "7 days", comment: "Delivery diagnostics export window")
        }
    }
}

/// Builds the one file needed to answer "is Trio delivering enough insulin,
/// quickly enough?".
///
/// The question has three separable causes, and no existing export separates
/// them, which is why it needs its own file rather than another column on the
/// ML export:
///
/// 1. **The algorithm never asked for more.** Visible in the per-cycle table:
///    `insulinReq` against what was recommended, next to the settings that cap
///    it. A `maxSMBBasalMinutes` of 30 with a 0.6 U/hr basal ceilings every SMB
///    at 0.3 U no matter how high glucose runs.
/// 2. **It asked, and the ask was reduced or dropped.** Visible in the command
///    table: `notSent` rows, delivery-cap clamps, and pump rejections. None of
///    these write a pump event, so they are invisible in pump history.
/// 3. **It asked, and the pump was slow.** Visible as command latency and as
///    gaps in the loop table. A 5-minute cycle that takes 90 seconds to reach
///    the pump delivers late even when every number is right.
///
/// Output is CSV in sections so it opens in a spreadsheet and still reads
/// top-to-bottom as a narrative.
protocol DeliveryDiagnosticsExporter {
    /// Writes the export and returns its URL (Documents/delivery_export/…csv).
    func export(window: DeliveryDiagnosticsWindow) async throws -> URL
}

final class BaseDeliveryDiagnosticsExporter: DeliveryDiagnosticsExporter, Injectable {
    /// Bump when columns change, so a shared file identifies its own layout.
    static let exportSchemaVersion = 1

    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var storage: FileStorage!
    @Injected() private var deliveryDiagnostics: DeliveryDiagnosticsRecorder!

    private let context: NSManagedObjectContext

    init(resolver: Resolver) {
        context = CoreDataStack.shared.newTaskContext()
        injectServices(resolver)
    }

    // MARK: - Export

    func export(window: DeliveryDiagnosticsWindow) async throws -> URL {
        let end = Date()
        let start = end.addingTimeInterval(-window.duration)

        let commands = deliveryDiagnostics.records(from: start, to: end)
        let capWindows = await storage.retrieveAsync(OpenAPS.Settings.deliveryCaps, as: [DeliveryCapWindow].self) ?? []
        let basalProfile = await storage.retrieveAsync(OpenAPS.Settings.basalProfile, as: [BasalProfileEntry].self) ?? []

        let cycles = try await fetchCycles(from: start)
        let pumpEvents = try await fetchPumpEvents(from: start)
        let loops = try await fetchLoops(from: start)

        var out = ""
        out += preamble(window: window, start: start, end: end)
        out += summarySection(cycles: cycles, commands: commands, loops: loops)
        out += settingsSection(capWindows: capWindows, basalProfile: basalProfile)
        out += cyclesSection(cycles, commands: commands)
        out += commandsSection(commands)
        out += pumpEventsSection(pumpEvents)
        out += loopsSection(loops)

        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let directory = documents.appendingPathComponent("delivery_export", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd'T'HHmmss"
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.locale = Locale(identifier: "en_US_POSIX")
        let url = directory
            .appendingPathComponent("trio-delivery-\(window.fileLabel)-\(stamp.string(from: end)).csv")

        try Data(out.utf8).write(to: url, options: .atomic)
        debug(
            .apsManager,
            "DeliveryDiagnostics: exported \(cycles.count) cycles, \(commands.count) commands to \(url.lastPathComponent)"
        )
        return url
    }

    // MARK: - Core Data reads
    //
    // Faulted managed objects are flattened into plain structs inside
    // `context.perform` so nothing downstream touches Core Data off its context.

    private struct CycleRow {
        let deliverAt: Date
        let enactedAt: Date?
        let glucose: Decimal?
        let minDelta: Decimal?
        let iob: Decimal?
        let cob: Int
        let insulinReq: Decimal?
        let recommendedRate: Decimal?
        let recommendedDurationMinutes: Decimal?
        let recommendedSMB: Decimal?
        let scheduledBasal: Decimal?
        let isf: Decimal?
        let carbRatio: Decimal?
        let sensitivityRatio: Decimal?
        let eventualBG: Decimal?
        let target: Decimal?
        let threshold: Decimal?
        let enacted: Bool
        let reason: String?
    }

    private struct PumpEventRow {
        let timestamp: Date
        let type: String?
        let bolusAmount: Decimal?
        let isSMB: Bool?
        let isExternal: Bool?
        let tempBasalRate: Decimal?
        let tempBasalDurationMinutes: Int?
    }

    private struct LoopRow {
        let start: Date?
        let end: Date?
        let durationMinutes: Double
        let intervalMinutes: Double
        let status: String?
    }

    private func fetchCycles(from start: Date) async throws -> [CycleRow] {
        try await context.perform { [context] in
            let request = OrefDetermination.fetchRequest()
            request.predicate = NSPredicate(format: "deliverAt >= %@", start as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "deliverAt", ascending: true)]
            return try context.fetch(request).compactMap { d -> CycleRow? in
                guard let deliverAt = d.deliverAt else { return nil }
                return CycleRow(
                    deliverAt: deliverAt,
                    enactedAt: d.timestampEnacted,
                    glucose: d.glucose?.decimalValue,
                    minDelta: d.minDelta?.decimalValue,
                    iob: d.iob?.decimalValue,
                    cob: Int(d.cob),
                    insulinReq: d.insulinReq?.decimalValue,
                    recommendedRate: d.rate?.decimalValue,
                    recommendedDurationMinutes: d.duration?.decimalValue,
                    recommendedSMB: d.smbToDeliver?.decimalValue,
                    scheduledBasal: d.scheduledBasal?.decimalValue,
                    isf: d.insulinSensitivity?.decimalValue,
                    carbRatio: d.carbRatio?.decimalValue,
                    sensitivityRatio: d.sensitivityRatio?.decimalValue,
                    eventualBG: d.eventualBG?.decimalValue,
                    target: d.currentTarget?.decimalValue,
                    threshold: d.threshold?.decimalValue,
                    enacted: d.enacted,
                    reason: d.reason
                )
            }
        }
    }

    private func fetchPumpEvents(from start: Date) async throws -> [PumpEventRow] {
        try await context.perform { [context] in
            let request = PumpEventStored.fetchRequest()
            request.predicate = NSPredicate(format: "timestamp >= %@", start as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: true)]
            request.relationshipKeyPathsForPrefetching = ["bolus", "tempBasal"]
            return try context.fetch(request).compactMap { event -> PumpEventRow? in
                guard let timestamp = event.timestamp else { return nil }
                return PumpEventRow(
                    timestamp: timestamp,
                    type: event.type,
                    bolusAmount: event.bolus?.amount?.decimalValue,
                    isSMB: event.bolus.map(\.isSMB),
                    isExternal: event.bolus.map(\.isExternal),
                    tempBasalRate: event.tempBasal?.rate?.decimalValue,
                    tempBasalDurationMinutes: event.tempBasal.map { Int($0.duration) }
                )
            }
        }
    }

    private func fetchLoops(from start: Date) async throws -> [LoopRow] {
        try await context.perform { [context] in
            let request = LoopStatRecord.fetchRequest()
            request.predicate = NSPredicate(format: "start >= %@", start as NSDate)
            request.sortDescriptors = [NSSortDescriptor(key: "start", ascending: true)]
            return try context.fetch(request).map {
                LoopRow(
                    start: $0.start,
                    end: $0.end,
                    durationMinutes: $0.duration,
                    intervalMinutes: $0.interval,
                    status: $0.loopStatus
                )
            }
        }
    }

    // MARK: - Sections

    private func preamble(window: DeliveryDiagnosticsWindow, start: Date, end: Date) -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        return """
        # Trio insulin delivery diagnostics
        # schemaVersion,\(Self.exportSchemaVersion)
        # generatedAt,\(iso(end))
        # window,\(window.fileLabel)
        # windowStart,\(iso(start))
        # windowEnd,\(iso(end))
        # appVersion,\(version) (\(build))
        # timesAreUTC,true
        #
        # Sections below are separated by blank lines; each starts with '## <name>'
        # and carries its own header row.


        """
    }

    /// The headline numbers. Everything here is derivable from the tables below,
    /// but the point of the file is to be readable at a glance before anyone
    /// opens a spreadsheet.
    private func summarySection(cycles: [CycleRow], commands: [DeliveryCommandRecord], loops: [LoopRow]) -> String {
        let smbCommands = commands.filter { $0.kind == .smb }
        let deliveredSMB = smbCommands.filter { $0.outcome == .succeeded }
        let latencies = commands.filter { $0.outcome != .notSent }.map(\.latencySeconds).sorted()

        // The gap that matters is between consecutive cycles: a 25-minute hole
        // means insulin was 20 minutes late regardless of what was dosed either side.
        let cycleTimes = cycles.map(\.deliverAt).sorted()
        let gaps = zip(cycleTimes, cycleTimes.dropFirst()).map { $1.timeIntervalSince($0) / 60 }

        var lines = ["## summary", "metric,value"]
        func add(_ key: String, _ value: String) { lines.append("\(csv(key)),\(csv(value))") }

        add("cycles", "\(cycles.count)")
        add("cycles enacted", "\(cycles.filter(\.enacted).count)")
        add("cycles recommending an SMB", "\(cycles.filter { ($0.recommendedSMB ?? 0) > 0 }.count)")
        add("SMB commands issued", "\(smbCommands.count)")
        add("SMB commands succeeded", "\(deliveredSMB.count)")
        add("SMB commands failed", "\(smbCommands.filter { $0.outcome == .failed }.count)")
        add("SMB commands never sent", "\(smbCommands.filter { $0.outcome == .notSent }.count)")
        // What the pump accepted, not necessarily what it finished delivering —
        // a cancelled or interrupted bolus still counts as an accepted command.
        // The pump_events section is the ground truth for delivered units.
        add("SMB units accepted by pump", dec(deliveredSMB.compactMap(\.requestedUnits).reduce(0, +)))
        add("temp basal commands issued", "\(commands.filter { $0.kind == .tempBasal }.count)")
        add(
            "commands failed or never sent",
            "\(commands.filter { $0.outcome == .failed || $0.outcome == .notSent }.count)"
        )
        add("commands clamped by a delivery cap", "\(commands.filter { !$0.clamps.isEmpty }.count)")
        add("command latency median (s)", latencies.isEmpty ? "" : num(percentile(latencies, 0.5)))
        add("command latency p95 (s)", latencies.isEmpty ? "" : num(percentile(latencies, 0.95)))
        add("command latency max (s)", latencies.isEmpty ? "" : num(latencies[latencies.count - 1]))
        add("loop cycles recorded", "\(loops.count)")
        add("loop cycles not successful", "\(loops.filter { ($0.status ?? "") != "Success" }.count)")
        add("longest gap between cycles (min)", gaps.isEmpty ? "" : num(gaps.max() ?? 0))
        add("median gap between cycles (min)", gaps.isEmpty ? "" : num(percentile(gaps.sorted(), 0.5)))

        return lines.joined(separator: "\n") + "\n\n"
    }

    /// Every setting that can hold delivery back, in one block.
    ///
    /// Nearly every "Trio is not giving me enough insulin" report is settled
    /// here rather than in the tables — a low Max Bolus, SMB left off for the
    /// current context, or a `maxSMBBasalMinutes` that ceilings SMBs well below
    /// what oref asked for.
    private func settingsSection(capWindows: [DeliveryCapWindow], basalProfile: [BasalProfileEntry]) -> String {
        let settings = settingsManager.settings
        let preferences = settingsManager.preferences
        let pump = settingsManager.pumpSettings

        var lines = ["## settings", "setting,value"]
        func add(_ key: String, _ value: String) { lines.append("\(csv(key)),\(csv(value))") }

        add("closedLoop", "\(settings.closedLoop)")
        add("glucoseUnits", settings.units.rawValue)

        add("maxBolus (U)", dec(pump.maxBolus))
        add("maxBasal (U/hr)", dec(pump.maxBasal))
        add("insulinActionCurve/DIA (h)", dec(pump.insulinActionCurve))
        add("maxIOB (U)", dec(preferences.maxIOB))
        add("maxCOB (g)", dec(preferences.maxCOB))

        add("enableSMBAlways", "\(preferences.enableSMBAlways)")
        add("enableSMBWithCOB", "\(preferences.enableSMBWithCOB)")
        add("enableSMBAfterCarbs", "\(preferences.enableSMBAfterCarbs)")
        add("enableSMBWithTemptarget", "\(preferences.enableSMBWithTemptarget)")
        add("allowSMBWithHighTemptarget", "\(preferences.allowSMBWithHighTemptarget)")
        add("enableSMB_high_bg", "\(preferences.enableSMB_high_bg)")
        add("enableSMB_high_bg_target", dec(preferences.enableSMB_high_bg_target))
        add("enableUAM", "\(preferences.enableUAM)")

        add("maxSMBBasalMinutes", dec(preferences.maxSMBBasalMinutes))
        add("maxUAMSMBBasalMinutes", dec(preferences.maxUAMSMBBasalMinutes))
        add("smbInterval (min)", dec(preferences.smbInterval))
        add("smbDeliveryRatio", dec(preferences.smbDeliveryRatio))
        add("bolusIncrement (U)", dec(preferences.bolusIncrement))

        add("insulinCurve", preferences.curve.rawValue)
        add("useCustomPeakTime", "\(preferences.useCustomPeakTime)")
        add("insulinPeakTime (min)", dec(preferences.insulinPeakTime))
        add("threshold_setting", dec(preferences.threshold_setting))
        add("maxDeltaBGthreshold", dec(preferences.maxDeltaBGthreshold))

        // Under dilution every U/hr and U figure in this file is a *pumped
        // volume*, not actual insulin — the factor is what reconciles them.
        add("allowDilution", "\(settings.allowDilution)")
        add("insulinConcentrationFactor", dec(settings.insulinConcentrationFactorDecimal))

        let dailyBasal = basalProfile.enumerated().reduce(Decimal(0)) { total, item in
            let (index, entry) = item
            let nextStart = index + 1 < basalProfile.count ? basalProfile[index + 1].minutes : 24 * 60
            return total + entry.rate * Decimal(nextStart - entry.minutes) / 60
        }
        add("basal profile entries", "\(basalProfile.count)")
        add("basal profile total (U/day)", dec(dailyBasal))
        add("basal profile min rate (U/hr)", basalProfile.isEmpty ? "" : dec(basalProfile.map(\.rate).min() ?? 0))
        add("basal profile max rate (U/hr)", basalProfile.isEmpty ? "" : dec(basalProfile.map(\.rate).max() ?? 0))

        add("scheduled delivery cap windows", "\(capWindows.count)")
        for (index, cap) in capWindows.enumerated() {
            add(
                "deliveryCap[\(index)]",
                "\(clock(cap.startMinutes))-\(clock(cap.endMinutes)) maxBasal \(dec(cap.maxBasalRate)) U/hr, maxSMB \(dec(cap.maxSMB)) U"
            )
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    private func cyclesSection(_ cycles: [CycleRow], commands: [DeliveryCommandRecord]) -> String {
        // Commands carry the deliverAt of the determination that produced them,
        // so the join is by identity rather than nearest-in-time.
        //
        // Bucketed to the second because the command side has been through
        // JSONL: ISO-8601 encoding drops sub-second precision, so the decoded
        // date is the truncated twin of the Core Data one and comparing them
        // directly would miss on nearly every row. Determinations are five
        // minutes apart, so a one-second bucket cannot collide.
        var byCycle: [Int: [DeliveryCommandRecord]] = [:]
        for command in commands {
            guard let deliverAt = command.determinationDeliverAt else { continue }
            byCycle[secondKey(deliverAt), default: []].append(command)
        }

        var lines = ["## cycles"]
        lines.append([
            "deliverAt", "enactedAt", "enactLagSec", "glucose", "minDelta", "iob", "cob",
            "insulinReq", "recTempRate", "recTempDurMin", "recSMB", "scheduledBasal",
            "isf", "carbRatio", "sensitivityRatio", "eventualBG", "target", "threshold",
            "enacted", "commands", "cmdOutcomes", "cmdMaxLatencySec", "clamps", "reason"
        ].joined(separator: ","))

        for cycle in cycles {
            let cycleCommands = byCycle[secondKey(cycle.deliverAt)] ?? []
            let outcomes = cycleCommands
                .map { "\($0.kind.rawValue):\($0.outcome.rawValue)" }
                .joined(separator: " ")
            let maxLatency = cycleCommands.filter { $0.outcome != .notSent }.map(\.latencySeconds).max()
            let clamps = Set(cycleCommands.flatMap(\.clamps)).sorted().joined(separator: "; ")
            let lag = cycle.enactedAt.map { $0.timeIntervalSince(cycle.deliverAt) }

            lines.append([
                iso(cycle.deliverAt),
                cycle.enactedAt.map(iso) ?? "",
                lag.map(num) ?? "",
                dec(cycle.glucose),
                dec(cycle.minDelta),
                dec(cycle.iob),
                "\(cycle.cob)",
                dec(cycle.insulinReq),
                dec(cycle.recommendedRate),
                dec(cycle.recommendedDurationMinutes),
                dec(cycle.recommendedSMB),
                dec(cycle.scheduledBasal),
                dec(cycle.isf),
                dec(cycle.carbRatio),
                dec(cycle.sensitivityRatio),
                dec(cycle.eventualBG),
                dec(cycle.target),
                dec(cycle.threshold),
                "\(cycle.enacted)",
                "\(cycleCommands.count)",
                csv(outcomes),
                maxLatency.map(num) ?? "",
                csv(clamps),
                csv(cycle.reason ?? "")
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    private func commandsSection(_ commands: [DeliveryCommandRecord]) -> String {
        var lines = ["## commands"]
        lines.append([
            "issuedAt", "kind", "requestedRate", "requestedDurMin", "requestedUnits",
            "outcome", "latencySec", "error", "determinationDeliverAt", "clamps"
        ].joined(separator: ","))

        for command in commands {
            lines.append([
                iso(command.issuedAt),
                command.kind.rawValue,
                dec(command.requestedRate),
                dec(command.requestedDurationMinutes),
                dec(command.requestedUnits),
                command.outcome.rawValue,
                command.outcome == .notSent ? "" : num(command.latencySeconds),
                csv(command.error ?? ""),
                command.determinationDeliverAt.map(iso) ?? "",
                csv(command.clamps.joined(separator: "; "))
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    private func pumpEventsSection(_ events: [PumpEventRow]) -> String {
        var lines = ["## pump_events"]
        lines.append([
            "timestamp", "type", "bolusAmount", "isSMB", "isExternal",
            "tempBasalRate", "tempBasalDurMin"
        ].joined(separator: ","))

        for event in events {
            lines.append([
                iso(event.timestamp),
                csv(event.type ?? ""),
                dec(event.bolusAmount),
                event.isSMB.map { "\($0)" } ?? "",
                event.isExternal.map { "\($0)" } ?? "",
                dec(event.tempBasalRate),
                event.tempBasalDurationMinutes.map { "\($0)" } ?? ""
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n\n"
    }

    private func loopsSection(_ loops: [LoopRow]) -> String {
        var lines = ["## loops"]
        lines.append(["start", "end", "durationMin", "intervalMin", "status"].joined(separator: ","))

        for loop in loops {
            lines.append([
                loop.start.map(iso) ?? "",
                loop.end.map(iso) ?? "",
                num(loop.durationMinutes),
                num(loop.intervalMinutes),
                csv(loop.status ?? "")
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Formatting

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func iso(_ date: Date) -> String {
        Self.isoFormatter.string(from: date)
    }

    /// Whole seconds since the epoch. Truncating (not rounding) is deliberate:
    /// it is what ISO-8601 encoding does to a date on its way into the command
    /// log, so both sides of the cycle join land in the same bucket.
    private func secondKey(_ date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    private func dec(_ value: Decimal?) -> String {
        guard let value else { return "" }
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, 4, .plain)
        return rounded.description
    }

    private func num(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Minutes since local midnight as HH:mm, for delivery cap windows.
    private func clock(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// Linear-interpolation percentile over an already-sorted array.
    private func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        guard sorted.count > 1 else { return sorted[0] }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        if lower == upper { return sorted[lower] }
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// RFC 4180 quoting. oref's `reason` string is full of commas and is the
    /// single most useful column in the file, so it has to survive intact.
    private func csv(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
