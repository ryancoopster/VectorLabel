import XCTest
@testable import VectorLabelCore

/// Regression tests for the senior-review fixes (2026-06-19) that harden the IPC
/// trust boundary: input validation before the encoders index a raster, and the
/// job `id` as an opaque, traversal-safe token rather than a path.
final class ReviewFixTests: XCTestCase {

    // MARK: RenderedLabel decode validates the raster invariant (F58 / F88)

    func testRenderedLabelDecodeRejectsPixelCountMismatch() {
        // 5 pixel bytes but declared 10×10 — would drive an out-of-bounds read in the
        // encoders, so decode MUST throw at the boundary.
        let bad = #"{"pixels":"AQIDBAU=","width":10,"height":10,"partNumber":""}"#  // 5 bytes
        XCTAssertThrowsError(try JSONDecoder().decode(RenderedLabel.self, from: Data(bad.utf8)))
    }

    func testRenderedLabelDecodeRejectsNonPositiveAndAbsurdDimensions() {
        let zero = #"{"pixels":"","width":0,"height":0,"partNumber":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RenderedLabel.self, from: Data(zero.utf8)))
        let huge = #"{"pixels":"AA==","width":1000000,"height":1000000,"partNumber":""}"#
        XCTAssertThrowsError(try JSONDecoder().decode(RenderedLabel.self, from: Data(huge.utf8)))
    }

    func testRenderedLabelDecodeAcceptsMatchingRaster() throws {
        let good = #"{"pixels":"AQIDBA==","width":2,"height":2,"partNumber":"M6-32"}"#  // 4 bytes
        let label = try JSONDecoder().decode(RenderedLabel.self, from: Data(good.utf8))
        XCTAssertEqual(label.width, 2)
        XCTAssertEqual(label.height, 2)
        XCTAssertEqual(label.bytes.count, 4)
        XCTAssertEqual(label.partNumber, "M6-32")
    }

    // MARK: PrintJobFile id / schema gating (F89 / F59 / F92)

    func testPrintJobFileRejectsMissingOrUnsafeId() {
        let missing = #"{"renderedLabels":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrintJobFile.self, from: Data(missing.utf8)))
        let traversal = #"{"id":"../../etc/passwd","renderedLabels":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrintJobFile.self, from: Data(traversal.utf8)))
        let slash = #"{"id":"a/b","renderedLabels":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrintJobFile.self, from: Data(slash.utf8)))
    }

    func testPrintJobFileAcceptsNormalId() {
        let ok = #"{"id":"job-123_ABC.json0","renderedLabels":[]}"#
        XCTAssertNoThrow(try JSONDecoder().decode(PrintJobFile.self, from: Data(ok.utf8)))
    }

    func testPrintJobFileRejectsNewerSchema() {
        let future = #"{"schema":99,"id":"abc","renderedLabels":[]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrintJobFile.self, from: Data(future.utf8)))
    }

    func testPrintJobFilePropagatesMalformedRasterToFailure() {
        // A present-but-invalid raster must PROPAGATE (so claim() routes the file to
        // failed/), not be swallowed into an empty job that "prints" zero labels.
        let mismatched = #"{"id":"abc","renderedLabels":[{"pixels":"AQ==","width":4,"height":4}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(PrintJobFile.self, from: Data(mismatched.utf8)))
    }

    func testIsSafeID() {
        XCTAssertTrue(PrintJobFile.isSafeID("ABC123"))
        XCTAssertTrue(PrintJobFile.isSafeID(UUID().uuidString))
        XCTAssertFalse(PrintJobFile.isSafeID(""))
        XCTAssertFalse(PrintJobFile.isSafeID("../x"))
        XCTAssertFalse(PrintJobFile.isSafeID("a/b"))
        XCTAssertFalse(PrintJobFile.isSafeID("a b"))
    }

    // MARK: readDoneJob never escapes done/ (F59)

    func testReadDoneJobRejectsTraversalId() {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vl-review-\(UUID().uuidString)", isDirectory: true)
        let q = PrintQueue(root: tmp)
        XCTAssertNil(q.readDoneJob(id: "../../../../etc/hosts"))
        XCTAssertNil(q.readDoneJob(id: "a/b"))
        XCTAssertNil(q.readDoneJob(id: "missing"))   // safe id, no file → nil, no crash
    }
}
