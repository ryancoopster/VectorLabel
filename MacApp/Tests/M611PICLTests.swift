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
