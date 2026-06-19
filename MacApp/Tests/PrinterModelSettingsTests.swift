import XCTest
@testable import VectorLabelCore

/// Per-model print settings (inter-label delay + full-job/single-label) added 2026-06-19,
/// plus the v1→v2 migration that seeds sensible defaults for existing installs.
final class PrinterModelSettingsTests: XCTestCase {

    func testMakeDefaultSeedsPerModelPrintSettings() {
        let d = PrinterModelList.makeDefault()
        XCTAssertEqual(d.version, 2)
        // M610 reports a hardware counter + historically printed one label at a time.
        XCTAssertEqual(d.models.first { $0.name == "M610" }?.singleLabelPrinting, true)
        // M611 defaults to one full job (coarse "Printing" unless it reports progress).
        XCTAssertEqual(d.models.first { $0.name == "M611" }?.singleLabelPrinting, false)
        XCTAssertEqual(d.models.first { $0.name == "M610" }?.interLabelDelayMs, 0)
    }

    func testTolerantDecodeDefaultsForMissingFields() throws {
        // A model written before the fields existed decodes to safe defaults.
        let json = #"{"id":"33333333-3333-3333-3333-333333333333","name":"X","usbIDs":[]}"#
        let m = try JSONDecoder().decode(PrinterModel.self, from: Data(json.utf8))
        XCTAssertEqual(m.interLabelDelayMs, 0)
        XCTAssertFalse(m.singleLabelPrinting)
    }

    func testV1MigrationSeedsDefaultsByName() throws {
        let v1 = """
        {"version":1,"models":[
          {"id":"11111111-1111-1111-1111-111111111111","name":"M610","usbIDs":[]},
          {"id":"22222222-2222-2222-2222-222222222222","name":"M611","usbIDs":[]}
        ]}
        """
        let decoded = try JSONDecoder().decode(PrinterModelList.self, from: Data(v1.utf8))
        XCTAssertEqual(decoded.version, 1)
        // Raw decode (pre-migration) gives the tolerant default for both.
        XCTAssertEqual(decoded.models.first { $0.name == "M610" }?.singleLabelPrinting, false)

        let migrated = decoded.migrated()
        XCTAssertEqual(migrated.version, 2)
        XCTAssertEqual(migrated.models.first { $0.name == "M610" }?.singleLabelPrinting, true)
        XCTAssertEqual(migrated.models.first { $0.name == "M611" }?.singleLabelPrinting, false)
    }

    func testMigratedIsNoopForCurrentVersion() {
        let d = PrinterModelList.makeDefault()   // already v2
        XCTAssertEqual(d.migrated(), d)
    }
}
