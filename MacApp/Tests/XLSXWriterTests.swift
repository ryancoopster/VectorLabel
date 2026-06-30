import XCTest
@testable import VectorLabelCore

final class XLSXWriterTests: XCTestCase {
    private func contains(_ b: [UInt8], _ sig: [UInt8]) -> Bool {
        guard b.count >= sig.count else { return false }
        for i in 0...(b.count - sig.count) where Array(b[i..<i+sig.count]) == sig { return true }
        return false
    }

    func testProducesValidZipStructure() throws {
        let headers = ["Number", "Cable", "Note"]
        let rows: [[String: String]] = [
            ["Number": "1", "Cable": "A & B <x>", "Note": "first"],
            ["Number": "2", "Cable": "C", "Note": ""],     // empty cell → omitted
        ]
        let data = try XCTUnwrap(XLSXWriter.data(headers: headers, rows: rows))
        let bytes = [UInt8](data)
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50, 0x4B, 0x03, 0x04], "local file header magic (PK\\03\\04)")
        XCTAssertTrue(contains(bytes, [0x50, 0x4B, 0x01, 0x02]), "central directory header present")
        XCTAssertTrue(contains(bytes, [0x50, 0x4B, 0x05, 0x06]), "end-of-central-directory present")
        // Emit for external (unzip/xml) validation by the harness.
        try data.write(to: URL(fileURLWithPath: "/tmp/vl_xlsx_test.xlsx"))
    }
}
