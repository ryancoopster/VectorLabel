import XCTest
@testable import VectorLabelCore
import PrinterM610
import PrinterM611
import PrinterBrother

/// The per-printer cut options each driver advertises, the new half-cut mode, and
/// the relay through the status file to the front-ends.
final class CutOptionsTests: XCTestCase {

    func testBradyDriversAdvertiseStandardCutOptions() {
        // M610/M611 use the Brady shear set: Every Label / End of Job / None (no half-cut).
        XCTAssertEqual(M610Module().capabilities.cutOptions, CutOption.bradyStandard)
        XCTAssertEqual(M611Module().capabilities.cutOptions, CutOption.bradyStandard)
        XCTAssertEqual(CutOption.bradyStandard.map { $0.mode }, [.eachLabel, .afterJobLast, .never])
        XCTAssertFalse(CutOption.bradyStandard.contains { $0.mode == .halfEachFullEnd })
    }

    func testBrotherAdvertisesHalfCutOption() {
        let opts = PTE550WModule().capabilities.cutOptions
        XCTAssertEqual(opts.count, 4)
        XCTAssertEqual(opts.first?.mode, .eachLabel)
        XCTAssertEqual(opts.first?.label, "Full cut every label")
        XCTAssertTrue(opts.contains { $0.mode == .halfEachFullEnd })
        XCTAssertEqual(opts.last?.mode, .never)
        // Every advertised mode is a real CutMode (round-trips through the raw value).
        for o in opts { XCTAssertEqual(CutMode(rawValue: o.mode.rawValue), o.mode) }
    }

    func testHalfCutModeCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(CutMode.halfEachFullEnd)
        XCTAssertEqual(try JSONDecoder().decode(CutMode.self, from: data), .halfEachFullEnd)
        XCTAssertEqual(CutMode.halfEachFullEnd.rawValue, "halfEachFullEnd")
    }

    func testStatusEntryRelaysCutOptions() throws {
        let entry = PrinterStatusEntry(
            id: "usb:1", name: "Brother PT-E550W", model: "PT-E550W", serial: "s",
            status: "ready", cassette: nil, activeJobCount: 0,
            cutOptions: PTE550WModule().capabilities.cutOptions)
        let data = try JSONEncoder().encode(entry)
        let back = try JSONDecoder().decode(PrinterStatusEntry.self, from: data)
        XCTAssertEqual(back.cutOptions, entry.cutOptions)
        XCTAssertTrue(back.cutOptions.contains { $0.mode == .halfEachFullEnd })
    }

    func testStatusEntryTolerantDecodeWithoutCutOptions() throws {
        // A status entry written before cutOptions existed still decodes (→ empty),
        // and the front-end falls back to the standard set for an empty list.
        let json = #"{"id":"x","name":"M610","model":"M610","serial":"s","status":"ready","activeJobCount":0}"#
        let back = try JSONDecoder().decode(PrinterStatusEntry.self, from: Data(json.utf8))
        XCTAssertEqual(back.cutOptions, [])
    }
}
