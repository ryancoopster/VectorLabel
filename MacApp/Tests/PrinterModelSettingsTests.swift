import XCTest
@testable import VectorLabelCore
import PrinterM611

/// Per-model print settings (inter-label delay + full-job/single-label) added 2026-06-19,
/// plus the v1→v2 migration that seeds sensible defaults for existing installs.
final class PrinterModelSettingsTests: XCTestCase {

    func testMakeDefaultSeedsPerModelPrintSettings() {
        let d = PrinterModelList.makeDefault()
        XCTAssertEqual(d.version, 3)
        // M610 reports a hardware counter + historically printed one label at a time.
        XCTAssertEqual(d.models.first { $0.name == "M610" }?.singleLabelPrinting, true)
        // M611 defaults to one full job (coarse "Printing" unless it reports progress).
        XCTAssertEqual(d.models.first { $0.name == "M611" }?.singleLabelPrinting, false)
        // Brother PT-E550W seeded with its USB id (VID 0x04F9 / PID 0x2060).
        let brother = d.models.first { $0.name == "PT-E550W" }
        XCTAssertEqual(brother?.usbIDs.first?.productID, "2060")
        XCTAssertEqual(brother?.usbIDs.first?.vendorID, "04F9")
    }

    func testTolerantDecodeDefaultsForMissingFields() throws {
        // A model written before the field existed decodes to a safe default.
        let json = #"{"id":"33333333-3333-3333-3333-333333333333","name":"X","usbIDs":[]}"#
        let m = try JSONDecoder().decode(PrinterModel.self, from: Data(json.utf8))
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
        XCTAssertEqual(migrated.version, 3)
        XCTAssertEqual(migrated.models.first { $0.name == "M610" }?.singleLabelPrinting, true)
        XCTAssertEqual(migrated.models.first { $0.name == "M611" }?.singleLabelPrinting, false)
        // v2→v3 also appends the Brother PT-E550W entry to existing installs.
        XCTAssertNotNil(migrated.models.first { $0.name == "PT-E550W" })
    }

    func testMigratedIsNoopForCurrentVersion() {
        let d = PrinterModelList.makeDefault()   // already v3
        XCTAssertEqual(d.migrated(), d)
    }

    func testV1MigrationMatchesM610ByUSBProductID() throws {
        // A renamed M610 (identified by PID 0x010B) still gets single-label on upgrade.
        let v1 = """
        {"version":1,"models":[
          {"id":"44444444-4444-4444-4444-444444444444","name":"Wire Printer",
           "usbIDs":[{"id":"55555555-5555-5555-5555-555555555555","vendorID":"0E2E","productID":"010B"}]}
        ]}
        """
        let migrated = try JSONDecoder().decode(PrinterModelList.self, from: Data(v1.utf8)).migrated()
        XCTAssertEqual(migrated.models.first?.singleLabelPrinting, true)
    }

    // MARK: connection methods (per-printer transports)

    func testEnabledTransportsDefaultsToAllOnDecode() throws {
        // A printer written before the field existed gets all methods enabled.
        let json = #"{"id":"66666666-6666-6666-6666-666666666666","name":"X","usbIDs":[]}"#
        let m = try JSONDecoder().decode(PrinterModel.self, from: Data(json.utf8))
        XCTAssertEqual(m.enabledTransports, Set(PrinterTransport.allCases))
    }

    func testEnabledTransportsAccessorDefaultsToAllForUnknownModel() {
        XCTAssertEqual(PrinterModelStore.enabledTransports(forName: "no-such-printer-zzz"),
                       Set(PrinterTransport.allCases))
    }

    func testM611DriverReportsSupportedTransports() {
        // The driver reports what it can drive — M611 = network + USB (USB print +
        // telemetry confirmed on hardware).
        XCTAssertEqual(M611Module().capabilities.supportedTransports, [.network, .usb])
    }
}
