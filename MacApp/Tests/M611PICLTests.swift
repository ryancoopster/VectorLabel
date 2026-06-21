import XCTest
import VectorLabelCore
@testable import PrinterM611

/// Brady M611 PICL telemetry protocol — framing + parsing (recovered from Brady's Web
/// SDK). These pin the high-confidence payload layer; the transport (TCP 9102 vs 9100)
/// is confirmed against real hardware separately.
final class M611PICLTests: XCTestCase {

    func testGetRequestFraming() {
        let req = M611PICL.getRequest()
        XCTAssertGreaterThan(req.count, 20)
        XCTAssertEqual(Array(req.prefix(16)), M611PICL.magic)
        let len = Int(req[16]) | Int(req[17]) << 8 | Int(req[18]) << 16 | Int(req[19]) << 24
        XCTAssertEqual(len, req.count - 20)                       // uint32-LE length == JSON length
        let json = String(bytes: req[20...], encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("PropertyGetRequests"))
        XCTAssertTrue(json.contains(M611PICL.firmwareDriver))
    }

    func testJobStatusRequestFramingScansSlots() {
        let req = M611PICL.jobStatusRequest()
        XCTAssertEqual(Array(req.prefix(16)), M611PICL.magic)
        let json = String(bytes: req[20...], encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("PropertyGetRequests"))
        XCTAssertTrue(json.contains(M611PICL.printSpooler))           // spooler component, not telemetry
        XCTAssertTrue(json.contains("Job 1:\(M611PICL.Job.externalId)"))
        XCTAssertTrue(json.contains("Job \(M611PICL.jobSlotScan):\(M611PICL.Job.status)"))
    }

    func testJobStateMatchesByExternalId() {
        // Two job slots; matching is by ExternalId (case-insensitive), independent of slot number.
        let mine = "VLABC0000000000000000000000PRNT"
        let json = """
        {"PropertyGetResponses":[\
        {"GUID":"Job 4:\(M611PICL.Job.externalId)","Value":"OTHER000000000000000000000000000"},\
        {"GUID":"Job 4:\(M611PICL.Job.status)","Value":"Print Complete"},\
        {"GUID":"Job 5:\(M611PICL.Job.externalId)","Value":"\(mine.lowercased())"},\
        {"GUID":"Job 5:\(M611PICL.Job.status)","Value":"Printing"}]}
        """
        let map = M611PICL.parse(Array(json.utf8))!
        XCTAssertEqual(M611PICL.jobState(in: map, externalId: mine), .printing)          // case-insensitive match
        XCTAssertEqual(M611PICL.jobState(in: map, externalId: "OTHER000000000000000000000000000"), .complete)
        XCTAssertEqual(M611PICL.jobState(in: map, externalId: "NOTPRESENT"), .absent)    // no slot → absent (not "done")
    }

    func testJobStateMissingOrReleasedStatusCountsComplete() {
        // A matched slot whose status property is absent, or "Property No Longer Available",
        // means the job finished and the slot is releasing — treat as complete, not stuck.
        let mine = "VLXYZ0000000000000000000000PRNT"
        let absent = "{\"PropertyGetResponses\":[{\"GUID\":\"Job 7:\(M611PICL.Job.externalId)\",\"Value\":\"\(mine)\"}]}"
        XCTAssertEqual(M611PICL.jobState(in: M611PICL.parse(Array(absent.utf8))!, externalId: mine), .complete)
        let released = """
        {"PropertyGetResponses":[\
        {"GUID":"Job 7:\(M611PICL.Job.externalId)","Value":"\(mine)"},\
        {"GUID":"Job 7:\(M611PICL.Job.status)","Value":"Property No Longer Available"}]}
        """
        XCTAssertEqual(M611PICL.jobState(in: M611PICL.parse(Array(released.utf8))!, externalId: mine), .complete)
    }

    func testCompletedCountTracksRealPerLabelProgress() {
        let ids = (0..<5).map { "VL000000000000000000000000\(String(format: "%04d", $0))" }
        func snap(_ pairs: [(Int, String?)]) -> [String: String] {
            var items = ""
            for (i, st) in pairs {
                items += "{\"GUID\":\"Job \(i):\(M611PICL.Job.externalId)\",\"Value\":\"\(ids[i])\"},"
                if let st { items += "{\"GUID\":\"Job \(i):\(M611PICL.Job.status)\",\"Value\":\"\(st)\"}," }
            }
            return M611PICL.parse(Array("{\"PropertyGetResponses\":[\(items.dropLast())]}".utf8))!
        }
        var started = Set<Int>(), observed = Set<Int>()
        func count(_ m: [String: String]) -> Int {
            M611PICL.completedCount(in: m, ids: ids, started: &started, observed: &observed)
        }
        // Label 0 printing, 1 queued → 0 done so far (0 in progress, 1 not started).
        XCTAssertEqual(count(snap([(0, "Printing"), (1, "")])), 0)
        // 0 complete, 1 printing → 1 done.
        XCTAssertEqual(count(snap([(0, "Print Complete"), (1, "Printing")])), 1)
        // 0 aged out (absent, but was STARTED), 1 complete, 2 printing → 2 done (FIFO order).
        XCTAssertEqual(count(snap([(1, "Print Complete"), (2, "Printing")])), 2)
        // A queued (.pending) label that then transiently vanishes must NOT be counted printed.
        var st = Set<Int>(), ob = Set<Int>()
        _ = M611PICL.completedCount(in: snap([(3, "")]), ids: ids, started: &st, observed: &ob)  // 3 queued
        let goneAfterQueued = M611PICL.parse(Array("{\"PropertyGetResponses\":[]}".utf8)) ?? [:]
        XCTAssertEqual(M611PICL.completedCount(in: goneAfterQueued, ids: ids, started: &st, observed: &ob), 0)
        // All slots aged out (empty snapshot) but all had STARTED → stays at the frontier.
        var st2 = Set([0, 1, 2, 3, 4]), ob2 = Set<Int>()
        XCTAssertEqual(M611PICL.completedCount(in: goneAfterQueued, ids: ids, started: &st2, observed: &ob2), 5)
    }

    func testParseExtractsJSONFromFramedResponse() {
        let sg = M611PICL.P.substrateGroup
        let json = """
        {"PropertyGetResponses":[\
        {"GUID":"\(M611PICL.P.batteryGroup):\(M611PICL.P.batteryCharge)","Value":"80"},\
        {"GUID":"\(sg):\(M611PICL.P.supplyRemaining)","Value":"62"},\
        {"GUID":"\(M611PICL.P.ribbonGroup):\(M611PICL.P.ribbonRemaining)","Value":"45"},\
        {"GUID":"\(sg):\(M611PICL.P.partNumber)","Value":"M6-32-427"}]}
        """
        // Arbitrary binary header before the JSON (parser must find + brace-match it).
        let bytes: [UInt8] = [0x8F, 0x99, 0x00, 0x01, 0x7E] + Array(json.utf8)
        let map = M611PICL.parse(bytes)
        XCTAssertEqual(map?["\(M611PICL.P.batteryGroup):\(M611PICL.P.batteryCharge)"], "80")
        XCTAssertEqual(map?["\(sg):\(M611PICL.P.supplyRemaining)"], "62")
    }

    func testCassetteStatusMapping() {
        let sg = M611PICL.P.substrateGroup
        let map = [
            "\(M611PICL.P.batteryGroup):\(M611PICL.P.batteryCharge)": "80",
            "\(sg):\(M611PICL.P.supplyRemaining)": "62",
            "\(M611PICL.P.ribbonGroup):\(M611PICL.P.ribbonRemaining)": "45",
            "\(sg):\(M611PICL.P.partNumber)": "M6-32-427",
            "\(sg):\(M611PICL.P.substrateWidth)": "1500",   // mils (thousandths of inch)
            "\(M611PICL.P.areaGroup):\(M611PICL.P.areaRotation)": "270",
        ]
        let cs = M611Module.cassetteStatus(from: map)
        XCTAssertEqual(cs?.batteryPct, 80)
        XCTAssertEqual(cs?.supplyRemainingPct, 62)
        XCTAssertEqual(cs?.ribbonRemainingPct, 45)
        XCTAssertEqual(cs?.partNumber, "M6-32-427")
        XCTAssertEqual(cs?.labelWidthMils, 1500)
        XCTAssertEqual(cs?.areaRotation, 270)
    }

    func testCassetteStatusParsesBoolFlags() {
        // The flags arrive string-coded ("True"/"False") on real firmware; integer
        // forms ("1"/"0") must also map so a different firmware still lights the UI.
        let sg = M611PICL.P.substrateGroup, eg = M611PICL.P.errorGroup, bg = M611PICL.P.batteryGroup
        let map = [
            "\(sg):\(M611PICL.P.partNumber)": "M6-32-427",
            "\(sg):\(M611PICL.P.isContinuous)": "False",
            "\(bg):\(M611PICL.P.acConnected)": "True",
            "\(eg):\(M611PICL.P.printheadOpen)": "False",
            "\(eg):\(M611PICL.P.substrateInvalid)": "True",
            "\(eg):\(M611PICL.P.ribbonInvalid)": "0",           // integer-coded false
        ]
        let cs = M611Module.cassetteStatus(from: map)
        XCTAssertEqual(cs?.isContinuous, false)
        XCTAssertEqual(cs?.acConnected, true)
        XCTAssertEqual(cs?.printheadOpen, false)
        XCTAssertEqual(cs?.substrateInvalid, true)
        XCTAssertEqual(cs?.ribbonInvalid, false)
    }

    func testParsePreservesJSONBooleanValues() {
        // A firmware that emits JSON booleans (true/false) rather than strings must
        // still map to canonical "true"/"false" — NOT "1"/"0" — so the flags survive.
        let sg = M611PICL.P.substrateGroup, eg = M611PICL.P.errorGroup
        let json = """
        {"PropertyGetResponses":[\
        {"GUID":"\(sg):\(M611PICL.P.partNumber)","Value":"M6-32-427"},\
        {"GUID":"\(eg):\(M611PICL.P.printheadOpen)","Value":true},\
        {"GUID":"\(eg):\(M611PICL.P.ribbonInvalid)","Value":false}]}
        """
        let bytes: [UInt8] = [0x00, 0x01] + Array(json.utf8)
        let map = M611PICL.parse(bytes)
        XCTAssertEqual(map?["\(eg):\(M611PICL.P.printheadOpen)"], "true")
        XCTAssertEqual(map?["\(eg):\(M611PICL.P.ribbonInvalid)"], "false")
        let cs = M611Module.cassetteStatus(from: map ?? [:])
        XCTAssertEqual(cs?.printheadOpen, true)
        XCTAssertEqual(cs?.ribbonInvalid, false)
    }

    func testParseReturnsNilForOpaqueResponse() {
        // No plain-text JSON (e.g. an LZ4-compressed response) → nil so readStatus logs it.
        XCTAssertNil(M611PICL.parse([0x04, 0x22, 0x4D, 0x18, 0xAA, 0xBB, 0xCC]))
        XCTAssertNil(M611PICL.parse([]))
    }
}
