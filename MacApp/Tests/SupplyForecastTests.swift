import XCTest
import VectorLabelCore
@testable import PrinterM611
@testable import PrinterM610

/// Plumbing for the supply-exhaustion forecast (the warning that a job may run the
/// loaded labels/ribbon out). The forecast math itself lives in the web UIs; these pin
/// the Swift values it depends on: the per-driver ribbon length, the catalog roll length,
/// and that the ribbon length survives the IPC status round-trip.
final class SupplyForecastTests: XCTestCase {

    func testRibbonLengthCapability() {
        // Both Brady drivers ship a 75 ft ribbon (900"), a fixed known per-driver value.
        XCTAssertEqual(M611Module().capabilities.ribbonLengthInches, 900, accuracy: 0.001)
        XCTAssertEqual(M610Module().capabilities.ribbonLengthInches, 900, accuracy: 0.001)
    }

    func testCatalogRollLengthFeet() {
        // Continuous parts carry a roll length (feet); unknown parts resolve to nil.
        XCTAssertEqual(BradyCatalog.rollLengthFeet(forPartNumber: "M6C-500-422"), 50)
        XCTAssertNil(BradyCatalog.rollLengthFeet(forPartNumber: "NOPE-0000-000"))
    }

    func testStatusEntryRibbonLengthRoundTrips() {
        let entry = PrinterStatusEntry(
            id: "net:1.2.3.4", name: "M611", model: "M611", serial: "S1",
            status: "ready", cassette: nil, activeJobCount: 0,
            supportsTelemetry: true, hasAutoCutter: true, ribbonLengthInches: 900)
        let data = try! JSONEncoder().encode(entry)
        let back = try! JSONDecoder().decode(PrinterStatusEntry.self, from: data)
        XCTAssertEqual(back.ribbonLengthInches, 900, accuracy: 0.001)
    }

    func testStatusEntryRibbonLengthTolerantDecode() {
        // A status file written before ribbonLengthInches existed must still decode (→ 0),
        // not drop the whole printers array.
        let json = """
        {"id":"x","name":"M611","model":"M611","serial":"S","status":"ready",
         "activeJobCount":0,"supportsTelemetry":true,"hasAutoCutter":true}
        """
        let back = try! JSONDecoder().decode(PrinterStatusEntry.self, from: Data(json.utf8))
        XCTAssertEqual(back.ribbonLengthInches, 0, accuracy: 0.001)
        XCTAssertTrue(back.supportsTelemetry)
    }
}
