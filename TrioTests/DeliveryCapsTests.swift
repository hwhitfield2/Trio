import Foundation
import Testing

@testable import Trio

@Suite("Delivery Caps Tests") struct DeliveryCapsTests {
    private func window(
        start: Int,
        end: Int,
        maxBasalRate: Decimal = 0,
        maxSMB: Decimal = 0
    ) -> DeliveryCapWindow {
        DeliveryCapWindow(startMinutes: start, endMinutes: end, maxBasalRate: maxBasalRate, maxSMB: maxSMB)
    }

    private func date(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 1
        components.day = 15
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components)!
    }

    // MARK: - Window matching

    @Test("Simple window matches inside, not outside") func testSimpleWindow() {
        let windows = [window(start: 8 * 60, end: 12 * 60)]
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 9, minute: 0)) != nil)
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 8, minute: 0)) != nil) // inclusive start
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 12, minute: 0)) == nil) // exclusive end
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 7, minute: 59)) == nil)
    }

    @Test("Window wrapping midnight matches both sides") func testMidnightWrap() {
        let windows = [window(start: 22 * 60, end: 6 * 60)]
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 23, minute: 30)) != nil)
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 2, minute: 0)) != nil)
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 6, minute: 0)) == nil)
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 12, minute: 0)) == nil)
    }

    @Test("start == end is a full-day window") func testFullDayWindow() {
        let windows = [window(start: 300, end: 300)]
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 0, minute: 0)) != nil)
        #expect(DeliveryCaps.activeCap(in: windows, at: date(hour: 23, minute: 59)) != nil)
    }

    @Test("Overlapping windows combine to the most restrictive cap") func testOverlapMostRestrictive() {
        let windows = [
            window(start: 0, end: 12 * 60, maxBasalRate: 2, maxSMB: 0.5),
            window(start: 8 * 60, end: 10 * 60, maxBasalRate: 0.5, maxSMB: 1),
        ]
        let cap = DeliveryCaps.activeCap(in: windows, at: date(hour: 9, minute: 0))
        #expect(cap == DeliveryCaps.ActiveCap(maxBasalRate: 0.5, maxSMB: 0.5))
    }

    @Test("No windows means no cap") func testNoWindows() {
        #expect(DeliveryCaps.activeCap(in: [], at: date(hour: 9, minute: 0)) == nil)
    }

    // MARK: - Scheduled rate lookup

    @Test("Scheduled rate uses last entry at or before now, wrapping to last of day") func testScheduledRate() {
        let entries: [(minutes: Int, rate: Decimal)] = [(0, 1), (6 * 60, 1.5), (22 * 60, 0.5)]
        #expect(DeliveryCaps.scheduledRate(from: entries, at: date(hour: 7, minute: 0)) == 1.5)
        #expect(DeliveryCaps.scheduledRate(from: entries, at: date(hour: 23, minute: 0)) == 0.5)
        #expect(DeliveryCaps.scheduledRate(from: entries, at: date(hour: 0, minute: 30)) == 1)
        #expect(DeliveryCaps.scheduledRate(from: [], at: date(hour: 0, minute: 30)) == 0)
    }

    // MARK: - Enactment resolution

    @Test("Zero cap: requested temp and SMB both go to zero") func testZeroCapClampsEverything() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 0, maxSMB: 0),
            determinationRate: 2,
            determinationDurationSeconds: 30 * 60,
            smb: 0.4,
            effectiveUncappedRate: 1
        )
        #expect(resolved.rate == 0)
        #expect(resolved.smb == 0)
        #expect(resolved.durationSeconds == 30 * 60)
        #expect(!resolved.notes.isEmpty)
    }

    @Test("Zero cap with no requested temp still issues a zero temp over scheduled basal") func testZeroCapEnforcesOverScheduled() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 0, maxSMB: 0),
            determinationRate: nil,
            determinationDurationSeconds: nil,
            smb: nil,
            effectiveUncappedRate: 1 // scheduled basal running
        )
        #expect(resolved.rate == 0)
        #expect(resolved.durationSeconds == 30 * 60)
        #expect(resolved.smb == nil)
    }

    @Test("Cap above delivery leaves everything untouched") func testCapAboveDeliveryNoOp() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 3, maxSMB: 1),
            determinationRate: 1.5,
            determinationDurationSeconds: 30 * 60,
            smb: 0.4,
            effectiveUncappedRate: 1
        )
        #expect(resolved.rate == 1.5)
        #expect(resolved.smb == 0.4)
        #expect(resolved.notes.isEmpty)
    }

    @Test("No requested temp and delivery already under cap: no temp issued") func testUnderCapNoTempIssued() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 2, maxSMB: 0),
            determinationRate: nil,
            determinationDurationSeconds: nil,
            smb: nil,
            effectiveUncappedRate: 1
        )
        #expect(resolved.rate == nil)
        #expect(resolved.durationSeconds == nil)
    }

    @Test("Partial cap clamps only what exceeds it") func testPartialCap() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 1, maxSMB: 0.2),
            determinationRate: 2.5,
            determinationDurationSeconds: 30 * 60,
            smb: 0.5,
            effectiveUncappedRate: 1
        )
        #expect(resolved.rate == 1)
        #expect(resolved.smb == 0.2)
        #expect(resolved.notes.count == 2)
    }

    @Test("Running temp hotter than cap is overridden even with no new request") func testRunningTempOverridden() {
        let resolved = DeliveryCaps.resolveEnactment(
            cap: .init(maxBasalRate: 0.5, maxSMB: 0),
            determinationRate: nil,
            determinationDurationSeconds: nil,
            smb: nil,
            effectiveUncappedRate: 2 // running temp at 2 U/hr
        )
        #expect(resolved.rate == 0.5)
        #expect(resolved.durationSeconds == 30 * 60)
    }
}
