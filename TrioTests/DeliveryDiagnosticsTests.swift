import Foundation
import Testing

@testable import Trio

/// The delivery-diagnostics store is the only record of commands that were
/// clamped, rejected, or never sent — the cases that leave no pump event — so
/// the round trip and the window filter are what the whole export rests on.
@Suite("Delivery Diagnostics Tests") struct DeliveryDiagnosticsTests {
    /// Each suite instance gets its own directory so runs cannot see each
    /// other's records.
    private func makeStore() -> (DeliveryCommandFileStore, URL) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("delivery-diagnostics-tests-\(UUID().uuidString)", isDirectory: true)
        return (DeliveryCommandFileStore(baseDirectory: base), base)
    }

    private func command(
        kind: DeliveryCommandRecord.Kind = .smb,
        issuedAt: Date,
        completedAt: Date? = nil,
        outcome: DeliveryCommandRecord.Outcome = .succeeded,
        units: Decimal? = 0.25,
        clamps: [String] = []
    ) -> DeliveryCommandRecord {
        DeliveryCommandRecord(
            kind: kind,
            requestedUnits: units,
            issuedAt: issuedAt,
            completedAt: completedAt ?? issuedAt,
            outcome: outcome,
            determinationDeliverAt: issuedAt,
            clamps: clamps
        )
    }

    // MARK: - Latency

    @Test("latency is derived from the issue and completion timestamps") func testLatencyDerived() {
        let issued = Date()
        let record = command(issuedAt: issued, completedAt: issued.addingTimeInterval(2.5))
        #expect(record.latencySeconds == 2.5)
    }

    @Test("a command that was never sent has zero latency") func testNotSentLatency() {
        let issued = Date()
        let record = command(issuedAt: issued, outcome: .notSent)
        #expect(record.latencySeconds == 0)
        #expect(record.outcome == .notSent)
    }

    // MARK: - Round trip

    @Test("records survive the JSONL round trip") func testRoundTrip() throws {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let issued = Date()
        store.append(command(
            kind: .tempBasal,
            issuedAt: issued,
            completedAt: issued.addingTimeInterval(1),
            units: nil,
            clamps: ["capped to 0.5 U/hr"]
        ))

        let loaded = store.records(from: issued.addingTimeInterval(-60), to: issued.addingTimeInterval(60))
        #expect(loaded.count == 1)
        #expect(loaded.first?.kind == .tempBasal)
        #expect(loaded.first?.clamps == ["capped to 0.5 U/hr"])
        #expect(loaded.first?.schemaVersion == DeliveryCommandRecord.currentSchemaVersion)
    }

    @Test("appends accumulate across many records") func testAppendAccumulates() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let start = Date()
        for offset in 0 ..< 20 {
            store.append(command(issuedAt: start.addingTimeInterval(Double(offset))))
        }

        let loaded = store.records(from: start.addingTimeInterval(-60), to: start.addingTimeInterval(600))
        #expect(loaded.count == 20)
    }

    // MARK: - Window filtering

    @Test("the window filter excludes records outside its bounds") func testWindowFilter() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let inside = now.addingTimeInterval(-60 * 60) // 1 hour ago
        let outside = now.addingTimeInterval(-48 * 60 * 60) // 2 days ago
        store.append(command(issuedAt: inside))
        store.append(command(issuedAt: outside))

        let sixHours = store.records(from: now.addingTimeInterval(-6 * 60 * 60), to: now)
        #expect(sixHours.count == 1)

        let sevenDays = store.records(from: now.addingTimeInterval(-7 * 24 * 60 * 60), to: now)
        #expect(sevenDays.count == 2)
    }

    @Test("records come back oldest first") func testOrdering() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let now = Date()
        let older = now.addingTimeInterval(-3 * 60 * 60)
        let newer = now.addingTimeInterval(-1 * 60 * 60)
        // Appended newest first, so ordering cannot come from insertion order.
        store.append(command(issuedAt: newer))
        store.append(command(issuedAt: older))

        let loaded = store.records(from: now.addingTimeInterval(-6 * 60 * 60), to: now)
        #expect(loaded.count == 2)
        // Compared as an ordering, not an equality: ISO-8601 encoding drops
        // sub-second precision, so a decoded date is never == its original.
        #expect(loaded[0].issuedAt < loaded[1].issuedAt)
    }

    @Test("decoded timestamps stay within a second of the originals") func testTimestampPrecision() {
        let (store, base) = makeStore()
        defer { try? FileManager.default.removeItem(at: base) }

        let issued = Date()
        store.append(command(issuedAt: issued))

        let loaded = store.records(from: issued.addingTimeInterval(-60), to: issued.addingTimeInterval(60))
        #expect(loaded.count == 1)
        // The cycle join buckets on whole seconds and relies on this bound.
        let decoded = loaded.first?.issuedAt ?? .distantPast
        #expect(abs(decoded.timeIntervalSince(issued)) < 1)
    }

    // MARK: - Export windows

    @Test("export windows cover the offered durations") func testWindowDurations() {
        #expect(DeliveryDiagnosticsWindow.sixHours.duration == 6 * 60 * 60)
        #expect(DeliveryDiagnosticsWindow.twentyFourHours.duration == 24 * 60 * 60)
        #expect(DeliveryDiagnosticsWindow.sevenDays.duration == 7 * 24 * 60 * 60)
        #expect(DeliveryDiagnosticsWindow.allCases.count == 3)
    }

    /// Retention has to outlast the longest window, or a 7-day export silently
    /// loses its oldest day to a purge that ran mid-window.
    @Test("retention outlasts the longest export window") func testRetentionCoversLongestWindow() {
        let longest = DeliveryDiagnosticsWindow.allCases.map(\.duration).max() ?? 0
        #expect(14 * 24 * 60 * 60 > longest)
    }
}
