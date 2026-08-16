import Foundation
import Testing

@testable import Trio

/// The insulin-type setting exists to stop the pump silently deciding which
/// insulin model oref doses against, so the mapping and the "explicit choice
/// wins" rule are the parts worth pinning.
@Suite("Insulin Type Selection Tests") struct InsulinTypeSelectionTests {
    @Test("automatic defers to the pump rather than naming a curve") func testAutomaticHasNoCurve() {
        #expect(InsulinTypeSelection.automatic.curve == nil)
    }

    @Test("rapid-acting insulins map to the rapid-acting curve") func testRapidActing() {
        #expect(InsulinTypeSelection.apidra.curve == .rapidActing)
        #expect(InsulinTypeSelection.humalog.curve == .rapidActing)
        #expect(InsulinTypeSelection.novolog.curve == .rapidActing)
    }

    @Test("ultra-rapid insulins map to the ultra-rapid curve") func testUltraRapid() {
        #expect(InsulinTypeSelection.fiasp.curve == .ultraRapid)
        #expect(InsulinTypeSelection.lyumjev.curve == .ultraRapid)
    }

    @Test("every insulin except automatic pins a curve") func testOnlyAutomaticIsUnpinned() {
        let unpinned = InsulinTypeSelection.allCases.filter { $0.curve == nil }
        #expect(unpinned == [.automatic])
    }

    @Test("a pump reporting nothing resolves to automatic") func testNoPumpInsulinType() {
        #expect(InsulinTypeSelection(pumpInsulinType: nil) == .automatic)
    }

    @Test("raw values are stable, so a stored setting survives an upgrade") func testRawValuesStable() {
        #expect(InsulinTypeSelection.automatic.rawValue == "automatic")
        #expect(InsulinTypeSelection.fiasp.rawValue == "fiasp")
        #expect(InsulinTypeSelection(rawValue: "lyumjev") == .lyumjev)
    }

    @Test("settings default to automatic, preserving the previous behaviour") func testDefaultIsAutomatic() {
        #expect(TrioSettings().insulinTypeSelection == .automatic)
    }

    @Test("the setting round-trips through JSON") func testRoundTrip() throws {
        var settings = TrioSettings()
        settings.insulinTypeSelection = .lyumjev

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(TrioSettings.self, from: data)
        #expect(decoded.insulinTypeSelection == .lyumjev)
    }

    /// Settings written before this option existed have no such key; decoding
    /// must fall back rather than throw.
    @Test("settings saved before the option existed still decode") func testBackwardCompatibleDecode() throws {
        let json = Data(#"{"units":"mg/dL"}"#.utf8)
        let decoded = try JSONDecoder().decode(TrioSettings.self, from: json)
        #expect(decoded.insulinTypeSelection == .automatic)
    }
}
