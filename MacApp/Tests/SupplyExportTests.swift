import XCTest
@testable import VectorLabelCore

/// The supply group/category import-export envelope (`SupplyExport`) + the fresh-id deep
/// copy used on import so an imported group/category can't collide with an existing one.
final class SupplyExportTests: XCTestCase {

    private func sampleGroup() -> SupplyGroup {
        SupplyGroup(name: "My Group", printerModels: ["M610", "M611"], categories: [
            SupplyCategory(name: "Cat A", supplies: [
                Supply(name: "1 × 2", kind: .dieCut, materialFamily: "B-593",
                       widthInches: 1, heightInches: 2, printableWidthInches: 1, printableHeightInches: 2,
                       parts: [SupplyPartNumber(partNumber: "M6-173-593", quantityPerRoll: 100)]),
            ]),
        ])
    }

    func testGroupExportRoundTrips() throws {
        let data = try JSONEncoder().encode(SupplyExport(group: sampleGroup()))
        let exp = try JSONDecoder().decode(SupplyExport.self, from: data)
        XCTAssertEqual(exp.format, SupplyExport.formatTag)
        XCTAssertNil(exp.category)
        XCTAssertEqual(exp.group?.name, "My Group")
        XCTAssertEqual(exp.group?.printerModels, ["M610", "M611"])
        XCTAssertEqual(exp.group?.categories.first?.supplies.first?.parts.first?.partNumber, "M6-173-593")
    }

    func testCategoryExportRoundTrips() throws {
        let data = try JSONEncoder().encode(SupplyExport(category: sampleGroup().categories[0]))
        let exp = try JSONDecoder().decode(SupplyExport.self, from: data)
        XCTAssertEqual(exp.format, SupplyExport.formatTag)
        XCTAssertNil(exp.group)
        XCTAssertEqual(exp.category?.name, "Cat A")
        XCTAssertEqual(exp.category?.supplies.first?.widthInches, 1)
    }

    func testWithFreshIDsChangesEveryIdButKeepsData() {
        let g = sampleGroup()
        let c = g.withFreshIDs()
        // Every level gets a new identity.
        XCTAssertNotEqual(c.id, g.id)
        XCTAssertNotEqual(c.categories[0].id, g.categories[0].id)
        XCTAssertNotEqual(c.categories[0].supplies[0].id, g.categories[0].supplies[0].id)
        XCTAssertNotEqual(c.categories[0].supplies[0].parts[0].id, g.categories[0].supplies[0].parts[0].id)
        // …but the content is identical.
        XCTAssertEqual(c.name, g.name)
        XCTAssertEqual(c.printerModels, g.printerModels)
        let p = c.categories[0].supplies[0].parts[0]
        XCTAssertEqual(p.partNumber, "M6-173-593")
        XCTAssertEqual(p.quantityPerRoll, 100)
    }
}
