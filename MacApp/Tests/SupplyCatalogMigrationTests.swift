import XCTest
@testable import VectorLabelCore

/// The catalog migration the designer/print snapshot applies on every load. Verifies
/// the Brother P-touch group is added (v1→v2) and refreshed to the corrected factory
/// definition (v2→v3: 2-decimal sizes + self-laminating), without disturbing other
/// (user-editable) groups.
final class SupplyCatalogMigrationTests: XCTestCase {

    private func brotherSupplies(_ c: SupplyCatalog) -> [Supply] {
        (c.groups.first { $0.serves(model: "PT-E550W") }?.categories ?? []).flatMap { $0.supplies }
    }

    func testMakeDefaultIsV4AndMigratedIsNoop() {
        let d = SupplyCatalog.makeDefault()
        XCTAssertEqual(d.version, 4)
        XCTAssertEqual(d.migrated(), d)
        // 2-decimal, self-laminating sizes in the factory default.
        let twelve = brotherSupplies(d).first { $0.name.hasPrefix("12") }!
        XCTAssertTrue(twelve.selfLaminating)
        XCTAssertEqual(twelve.widthInches, 0.47, accuracy: 0.0001)
        XCTAssertEqual(twelve.printableWidthInches, 0.39, accuracy: 0.0001)
    }

    func testV1AddsBrotherGroup() {
        let v1 = SupplyCatalog(version: 1,
            groups: [SupplyGroup(name: "Brady M6", printerModels: ["M610", "M611"], categories: [])],
            coreEquivalences: [:])
        let m = v1.migrated()
        XCTAssertEqual(m.version, 4)
        XCTAssertNotNil(m.groups.first { $0.name == "Brady M6" })       // preserved
        XCTAssertNotNil(m.groups.first { $0.serves(model: "PT-E550W") }) // added
        XCTAssertEqual(brotherSupplies(m).count, 6)                      // all six TZe widths
    }

    func testV2RefreshesStaleBrotherGroup() {
        // A v2 install whose Brother group has the OLD full-precision, non-laminating
        // values must be refreshed in place; the Brady group is left untouched.
        let stale = Supply(name: "12 mm continuous", kind: .continuous, selfLaminating: false,
                           materialFamily: "TZe", widthInches: 0.4724409448818898, heightInches: 1,
                           printableWidthInches: 0.3888888888888889, printableHeightInches: 1, parts: [])
        let v2 = SupplyCatalog(version: 2, groups: [
            SupplyGroup(name: "Brady M6", printerModels: ["M610"], categories: []),
            SupplyGroup(name: "Brother P-touch", printerModels: ["PT-E550W", "PT-P750W", "PT-E560BT"],
                        categories: [SupplyCategory(name: "TZe Laminated Tapes", supplies: [stale])]),
        ], coreEquivalences: [:])

        let m = v2.migrated()
        XCTAssertEqual(m.version, 4)
        XCTAssertNotNil(m.groups.first { $0.name == "Brady M6" })        // untouched
        XCTAssertEqual(m.groups.filter { $0.serves(model: "PT-E550W") }.count, 1)  // not duplicated
        let twelve = brotherSupplies(m).first { $0.name.hasPrefix("12") }!
        XCTAssertTrue(twelve.selfLaminating)                            // now self-laminating
        XCTAssertEqual(twelve.widthInches, 0.47, accuracy: 0.0001)      // rounded to 2 decimals
        XCTAssertEqual(twelve.printableWidthInches, 0.39, accuracy: 0.0001)
    }

    func testV3AddsMissingRaisedPanelSizes() {
        // A v3 install with only the old 2 raised-panel sizes (173, 174) plus a user's own
        // custom category must GAIN the missing sizes (171, 176) and KEEP the custom one.
        func panel(_ pn: String, _ w: Double, _ h: Double) -> Supply {
            Supply(name: pn, kind: .dieCut, materialFamily: "B-593", widthInches: w, heightInches: h,
                   printableWidthInches: w, printableHeightInches: h,
                   parts: [SupplyPartNumber(partNumber: pn)])
        }
        let custom = Supply(name: "my custom", kind: .dieCut, materialFamily: "X",
                            widthInches: 1, heightInches: 1, printableWidthInches: 1, printableHeightInches: 1,
                            parts: [SupplyPartNumber(partNumber: "CUSTOM-1")])
        let v3 = SupplyCatalog(version: 3, groups: [
            SupplyGroup(name: "Brady M6", printerModels: ["M610", "M611"], categories: [
                SupplyCategory(name: "Raised Panel Labels",
                               supplies: [panel("M6-173-593", 1, 2), panel("M6-174-593", 1, 4)]),
                SupplyCategory(name: "My Stuff", supplies: [custom]),
            ]),
        ], coreEquivalences: [:])

        let m = v3.migrated()
        XCTAssertEqual(m.version, 4)
        let cat = m.groups.first!.categories.first { $0.name == "Raised Panel Labels" }!
        XCTAssertEqual(cat.supplies.count, 4)                            // no duplicates
        XCTAssertEqual(Set(cat.supplies.flatMap { $0.parts.map { $0.partNumber } }),
                       ["M6-171-593", "M6-173-593", "M6-174-593", "M6-176-593"])
        XCTAssertNotNil(m.groups.first!.categories.first { $0.name == "My Stuff" })  // preserved
        XCTAssertEqual(m.migrated(), m)                                  // idempotent (now v4)
    }
}
