import Foundation

/// Brady **"full PICL"** property protocol for the M611 — the status/telemetry
/// channel (supply %, ribbon %, battery %, substrate part + dimensions).
///
/// The framing, component/group/property GUIDs, and request/response JSON shape were
/// recovered from Brady's own shipped Web SDK (`@bradycorporation/brady-web-sdk`), so
/// the **payload is high-confidence**. The one inference is the **transport**: the Web
/// SDK carries PICL over BLE GATT, not TCP — so "this PICL frame over TCP 9102 (or the
/// bidirectional 9100 print socket)" is a hypothesis `M611Module.readStatus` confirms
/// against real hardware (it tries both ports and logs what comes back).
///
/// A request frame is `[16-byte magic] + [uint32-LE JSON length] + UTF-8 JSON` — the
/// same envelope as a print segment (`M611Bitmap.segment`) but with a DIFFERENT magic.
enum M611PICL {

    /// 16-byte "full PICL" magic (M611 / i7500 / i4311). NOT the print magic.
    static let magic: [UInt8] = [0xB3, 0xEC, 0x09, 0x9A, 0x22, 0x92, 0x48, 0xFA,
                                 0x83, 0xD0, 0x06, 0x84, 0x0B, 0xC9, 0x91, 0x02]

    /// All telemetry lives under this component (the printer's FirmwareDriver).
    static let firmwareDriver = "B80EB2EA-4F49-423A-875C-8ACB1ACB9734"

    /// group:property GUIDs (under `firmwareDriver`).
    enum P {
        static let substrateGroup   = "41B87577-BD88-48CE-BF21-BF5A6BFC9FE3"
        static let supplyRemaining  = "946A015D-6FE0-42B8-A194-79994463B4D3"  // % (= labels remaining)
        static let partNumber       = "1F59F145-04F2-4199-ABC9-4FA9BDEC89EB"
        static let substrateWidth   = "DA6D0191-4329-4E8C-9B68-456ACEB4F7DF"
        static let substrateHeight  = "0A610815-EE87-45D1-8CC8-1C719C558332"
        static let printableWidth   = "921C0E3E-45F4-466E-B748-CA1509E75C9D"
        static let printableHeight  = "FCD0EDDD-3D48-427D-B27C-0D2D7BBC8AC2"
        static let isDieCut         = "1BC6EE50-5F32-4CAA-8D32-D70167E0792D"
        static let ribbonGroup      = "CC359C57-F0F2-44E3-9940-3F1BFF1685BC"
        static let ribbonRemaining  = "5DA4C82D-C498-4DB2-A87A-D65499E225A0"  // %
        static let ribbonName       = "349FA937-C9C0-4605-A382-B5FEE4A56C0D"  // ribbon part # (e.g. R4310)
        static let batteryGroup     = "FDA4C5D4-8C46-45E5-80E4-48504451C7B5"
        static let batteryCharge    = "62160CE4-7FED-4F3B-BE27-9D773CFB84DC"  // %
        // AreaRotation's group is the literal string "Substrate Area 0" — confirmed on
        // hardware to resolve directly (no boot-packet handshake needed).
        static let areaGroup        = "Substrate Area 0"
        static let areaRotation     = "E7CBB620-9556-4979-AEF0-76DAB1FBAC8E"  // degrees
        // Printer identity (group "Printer Properties").
        static let printerGroup     = "222D688A-1554-4C0E-B7A0-0BC377EF4071"
        static let serial           = "AE2955D7-1AE3-4520-BB1C-1DC0C2B5A58B"  // "Printer Serial Number"
        static let firmware         = "ACEB1224-1DAF-42A2-BBAA-4678D5D3C8DA"  // "Firmware Version"
    }

    /// The (group, property) pairs we query. (AreaRotation is intentionally omitted —
    /// its group GUID is per-area and only discoverable from the connect-time "boot
    /// packet"; until that's wired up, encode() keeps its 270 fallback.)
    static let requested: [(group: String, prop: String)] = [
        (P.substrateGroup, P.supplyRemaining), (P.substrateGroup, P.partNumber),
        (P.substrateGroup, P.substrateWidth),  (P.substrateGroup, P.substrateHeight),
        (P.substrateGroup, P.printableWidth),  (P.substrateGroup, P.printableHeight),
        (P.substrateGroup, P.isDieCut),
        (P.ribbonGroup, P.ribbonRemaining),    (P.ribbonGroup, P.ribbonName),
        (P.batteryGroup, P.batteryCharge),     (P.areaGroup, P.areaRotation),
        (P.printerGroup, P.serial),            (P.printerGroup, P.firmware),
    ]

    /// A framed `PropertyGetRequest` for all the telemetry properties above.
    static func getRequest() -> [UInt8] {
        let reqs = requested.map { ["Component": firmwareDriver, "GUID": "\($0.group):\($0.prop)"] }
        guard let json = try? JSONSerialization.data(withJSONObject: ["PropertyGetRequests": reqs]) else { return [] }
        let len = UInt32(json.count)
        var out = magic
        out += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)]
        out += [UInt8](json)
        return out
    }

    /// Parse a PICL response into `["group:prop": value]`. Resilient to the unconfirmed
    /// transport framing: it locates the `PropertyGetResponses` JSON object inside the
    /// raw bytes (whatever magic/length/header precedes it) and brace-matches it out.
    /// Returns nil if no plain-text JSON is present (e.g. an LZ4-compressed response —
    /// readStatus logs the raw bytes in that case so the exact framing can be decoded
    /// from a real-hardware sample).
    static func parse(_ bytes: [UInt8]) -> [String: String]? {
        let needle = Array("PropertyGetResponses".utf8)
        guard let m = firstIndex(of: needle, in: bytes) else { return nil }
        var start = m
        while start > 0 && bytes[start] != UInt8(ascii: "{") { start -= 1 }
        guard bytes[start] == UInt8(ascii: "{") else { return nil }

        var depth = 0, end = -1, inStr = false, esc = false, i = start
        while i < bytes.count {
            let ch = bytes[i]
            if inStr {
                if esc { esc = false }
                else if ch == 0x5C { esc = true }          // backslash
                else if ch == 0x22 { inStr = false }       // "
            } else if ch == 0x22 { inStr = true }
            else if ch == 0x7B { depth += 1 }              // {
            else if ch == 0x7D { depth -= 1; if depth == 0 { end = i; break } }   // }
            i += 1
        }
        guard end >= start,
              let obj = try? JSONSerialization.jsonObject(with: Data(bytes[start...end])) as? [String: Any],
              let responses = obj["PropertyGetResponses"] as? [[String: Any]] else { return nil }

        var map: [String: String] = [:]
        for r in responses {
            guard let guid = r["GUID"] as? String else { continue }
            if let v = r["Value"] as? String { map[guid] = v }
            else if let v = r["Value"] { map[guid] = "\(v)" }
        }
        return map.isEmpty ? nil : map
    }

    private static func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for s in 0...(hay.count - needle.count) {
            var ok = true
            for k in 0 ..< needle.count where hay[s + k] != needle[k] { ok = false; break }
            if ok { return s }
        }
        return nil
    }
}
