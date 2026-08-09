import Foundation
import Testing

@testable import Trio

@Suite("Site Tracker Tests") struct SiteTrackerTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func input(
        baselineTDD: Double = 40,
        recentTDD: Double = 50,
        baselineMeanBG: Double = 140,
        recentMeanBG: Double = 170,
        siteAgeHours: Double = 80,
        baselineHours: Double = 48,
        hasBaselineSamples: Bool = true,
        hasRecentSamples: Bool = true
    ) -> SiteDegradationPolicy.Input {
        SiteDegradationPolicy.Input(
            baselineTDD: baselineTDD,
            recentTDD: recentTDD,
            baselineMeanBG: baselineMeanBG,
            recentMeanBG: recentMeanBG,
            siteAgeHours: siteAgeHours,
            baselineHours: baselineHours,
            hasBaselineSamples: hasBaselineSamples,
            hasRecentSamples: hasRecentSamples
        )
    }

    // MARK: - Degradation policy

    @Test("Fires only when every condition is met") func testAllConditionsMet() {
        // 50/40 = 1.25 > 1.2 and 170/140 ≈ 1.21 > 1.15
        #expect(SiteDegradationPolicy.evaluate(input()))
    }

    @Test("Does not fire before 72 hours of site age") func testSiteAgeBoundary() {
        #expect(!SiteDegradationPolicy.evaluate(input(siteAgeHours: 71.9)))
        #expect(SiteDegradationPolicy.evaluate(input(siteAgeHours: 72)))
    }

    @Test("Requires at least 36 hours of baseline coverage") func testBaselineCoverageBoundary() {
        #expect(!SiteDegradationPolicy.evaluate(input(baselineHours: 35.9)))
        #expect(SiteDegradationPolicy.evaluate(input(baselineHours: 36)))
    }

    @Test("TDD ratio boundary: 1.19x no, 1.21x yes") func testTDDRatioBoundary() {
        #expect(!SiteDegradationPolicy.evaluate(input(baselineTDD: 40, recentTDD: 40 * 1.19)))
        #expect(!SiteDegradationPolicy.evaluate(input(baselineTDD: 40, recentTDD: 40 * 1.2)))
        #expect(SiteDegradationPolicy.evaluate(input(baselineTDD: 40, recentTDD: 40 * 1.21)))
    }

    @Test("BG ratio boundary: 1.14x no, 1.16x yes") func testBGRatioBoundary() {
        #expect(!SiteDegradationPolicy.evaluate(input(baselineMeanBG: 140, recentMeanBG: 140 * 1.14)))
        #expect(!SiteDegradationPolicy.evaluate(input(baselineMeanBG: 140, recentMeanBG: 140 * 1.15)))
        #expect(SiteDegradationPolicy.evaluate(input(baselineMeanBG: 140, recentMeanBG: 140 * 1.16)))
    }

    @Test("Missing samples suppress the notice") func testInsufficientSamples() {
        #expect(!SiteDegradationPolicy.evaluate(input(hasBaselineSamples: false)))
        #expect(!SiteDegradationPolicy.evaluate(input(hasRecentSamples: false)))
    }

    @Test("Zero baselines never fire") func testZeroBaselines() {
        #expect(!SiteDegradationPolicy.evaluate(input(baselineTDD: 0, recentTDD: 10)))
        #expect(!SiteDegradationPolicy.evaluate(input(baselineMeanBG: 0, recentMeanBG: 100)))
    }

    // MARK: - Dedup window

    @Test("Dates within ±60 minutes are duplicates") func testDedupWithinWindow() {
        let existing = [now]
        #expect(SiteChangeDedup.isDuplicate(existing: existing, candidate: now))
        #expect(SiteChangeDedup.isDuplicate(existing: existing, candidate: now.addingTimeInterval(59 * 60)))
        #expect(SiteChangeDedup.isDuplicate(existing: existing, candidate: now.addingTimeInterval(-59 * 60)))
        #expect(SiteChangeDedup.isDuplicate(existing: existing, candidate: now.addingTimeInterval(60 * 60)))
    }

    @Test("Dates beyond the window are distinct") func testDedupOutsideWindow() {
        let existing = [now]
        #expect(!SiteChangeDedup.isDuplicate(existing: existing, candidate: now.addingTimeInterval(61 * 60)))
        #expect(!SiteChangeDedup.isDuplicate(existing: existing, candidate: now.addingTimeInterval(-61 * 60)))
        #expect(!SiteChangeDedup.isDuplicate(existing: [], candidate: now))
    }

    @Test("A rewind and a site change for the same swap collapse") func testRewindSiteChangePair() {
        // Rewind at t, SiteChange 4 minutes later - the second mirrors as a duplicate.
        var known = [Date]()
        let rewind = now
        let siteChange = now.addingTimeInterval(4 * 60)
        #expect(!SiteChangeDedup.isDuplicate(existing: known, candidate: rewind))
        known.append(rewind)
        #expect(SiteChangeDedup.isDuplicate(existing: known, candidate: siteChange))
    }

    // MARK: - Rotation summary

    @Test("Summary counts per location and tracks last use") func testRotationSummary() {
        let changes: [(location: SiteBodyLocation?, date: Date)] = [
            (.leftAbdomen, now.addingTimeInterval(-10 * 86400)),
            (.leftAbdomen, now.addingTimeInterval(-3 * 86400)),
            (.rightThigh, now.addingTimeInterval(-6 * 86400)),
            (nil, now.addingTimeInterval(-1 * 86400))
        ]
        let summary = SiteRotationMath.summary(of: changes)

        #expect(summary.count == 2)
        #expect(summary.first?.location == .leftAbdomen)
        #expect(summary.first?.count == 2)
        #expect(summary.first?.lastUsed == now.addingTimeInterval(-3 * 86400))
        #expect(summary.last?.location == .rightThigh)
        #expect(summary.last?.count == 1)
    }

    @Test("Heavy-use flag at the 40% share boundary") func testHeavyUse() {
        #expect(SiteRotationMath.isHeavilyUsed(count: 4, total: 10))
        #expect(!SiteRotationMath.isHeavilyUsed(count: 3, total: 10))
        #expect(!SiteRotationMath.isHeavilyUsed(count: 0, total: 0))
    }

    @Test("Rested flag after 30 days without use") func testRested() {
        #expect(SiteRotationMath.isRested(lastUsed: now.addingTimeInterval(-31 * 86400), now: now))
        #expect(!SiteRotationMath.isRested(lastUsed: now.addingTimeInterval(-29 * 86400), now: now))
        #expect(!SiteRotationMath.isRested(lastUsed: nil, now: now))
    }
}
