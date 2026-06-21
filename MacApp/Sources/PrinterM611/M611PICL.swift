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

    /// The print-spooler component (job queue + per-job status). Confirmed reachable on the
    /// SAME channel as telemetry — TCP:9102 and USB vendor iface (probe read TotalJobsQueued
    /// here mid-print). Jobs live in numbered slots named by the literal string "Job N".
    static let printSpooler = "90AF7DE7-6DB1-45AF-A46F-C66605612E61"

    /// Per-job property GUIDs (group = the slot name "Job N").
    enum Job {
        static let externalId = "09ADF412-B765-4E71-A202-E93762F4442F"   // == our print's JobID
        static let status     = "B32A3258-62D1-4E43-8D73-3B352B61B6C8"   // ""→Streaming→Printing→Print Complete
        static let complete   = "Print Complete"
        static let gone       = "Property No Longer Available"           // slot releasing → also finished
    }
    /// Job lifecycle reading for one matched slot. Status goes ""→Streaming→Printing→Print
    /// Complete, then the slot releases (status drops / "Property No Longer Available").
    enum JobState: Equatable {
        case absent          // no slot currently holds this ExternalId (not queued yet, or aged out)
        case pending         // present but status "" — queued, NOT started printing
        case printing        // present + Streaming/Printing — actively printing
        case complete        // "Print Complete" / status released → finished
    }
    /// The printer keeps a small ring of recent job slots (observed "Job 4"/"Job 5" with
    /// hundreds queued), so scanning 1…N and matching by ExternalId finds ours regardless
    /// of the slot number it lands in.
    static let jobSlotScan = 32

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
        // Media flags + pre-flight error/validity.
        static let isContinuous     = "1AB35077-D002-403D-899B-C59CFF7D111E"  // substrateGroup
        static let yNumber          = "778B241E-BEA5-4600-8871-D5EAF833B775"  // substrateGroup
        static let acConnected      = "ECDD0A3C-DFCB-4F47-A2EA-235C5803657C"  // batteryGroup
        static let errorGroup       = "2EBF9DEF-D51C-47FE-935E-5EDCC530B867"
        static let printheadOpen    = "33A0B25B-1660-4F29-9AF3-40B70CE291B2"
        static let substrateInvalid = "3033B200-8D64-4D46-A50E-12E93BA03F42"
        static let ribbonInvalid    = "FB01FE2F-A52D-4A67-A8D5-B4D122CD4B43"
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
        (P.substrateGroup, P.isContinuous),    (P.substrateGroup, P.yNumber),
        (P.batteryGroup, P.acConnected),
        (P.errorGroup, P.printheadOpen),       (P.errorGroup, P.substrateInvalid),
        (P.errorGroup, P.ribbonInvalid),
    ]

    /// A framed `PropertyGetRequest` for all the telemetry properties above.
    static func getRequest() -> [UInt8] {
        let reqs = requested.map { ["Component": firmwareDriver, "GUID": "\($0.group):\($0.prop)"] }
        return request(reqs)
    }

    /// Request the printer enumerate ALL current properties. Job slots are DYNAMIC — a
    /// targeted property-get of `Job N:<prop>` returns "Invalid Value" — so the only way to
    /// read job status is this "subscribe to all" call (the model Brady's own software uses).
    /// The reply lists every property, including the live job slots, which `jobState`/
    /// `completedCount` pick out by ExternalId. (Confirmed against the M611 packet capture.)
    static func jobStatusRequest() -> [UInt8] {
        guard let json = try? JSONSerialization.data(
            withJSONObject: ["SubscribeAllCurrentAndNewProperties": [String]()]) else { return [] }
        let len = UInt32(json.count)
        var out = magic
        out += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)]
        out += [UInt8](json)
        return out
    }

    /// The lifecycle state of our job in a parsed PICL response. Scans whatever job slots the
    /// response actually returned (matched by ExternalId, case-insensitively) rather than
    /// assuming a slot-number range, so it's robust to however the firmware names slots. A
    /// matched slot whose status property is missing or "Property No Longer Available" counts
    /// as `.complete` (the slot is releasing after the job finished). Returns `.absent` when no
    /// returned slot holds our ExternalId — the CALLER must distinguish that from a failed
    /// round-trip (parse == nil), which is transient and means "unknown", not "done".
    static func jobState(in map: [String: String], externalId: String) -> JobState {
        let suffix = ":\(Job.externalId)"
        for (key, value) in map where key.hasSuffix(suffix)
            && value.caseInsensitiveCompare(externalId) == .orderedSame {
            let group = String(key.dropLast(suffix.count))         // the slot name, e.g. "Job 5"
            let status = map["\(group):\(Job.status)"]
            if status == nil || status == Job.complete || status == Job.gone { return .complete }
            if status == "" { return .pending }                    // queued, not started printing yet
            return .printing                                       // Streaming / Printing
        }
        return .absent
    }

    /// How many labels in `ids` (in send order) the printer has confirmed printed, from one
    /// status snapshot, using FIFO print order. A label is done if its slot reports complete,
    /// or it actually STARTED printing earlier and its slot has since aged out; every label
    /// before one that has started is also done. `started` tracks only indices seen .printing
    /// or .complete — a merely-queued (.pending) label is NOT credited if its slot transiently
    /// vanishes (that would over-count and end the job early). `observed` tracks ANY slot we
    /// saw (incl. queued), for the caller's "is job telemetry reporting our jobs at all?" check.
    /// Monotonic source — callers keep the running max (a transient snapshot can omit a slot).
    static func completedCount(in map: [String: String], ids: [String],
                               started: inout Set<Int>, observed: inout Set<Int>) -> Int {
        var done = 0
        for (i, id) in ids.enumerated() {
            switch jobState(in: map, externalId: id) {
            case .complete: started.insert(i); observed.insert(i); done = max(done, i + 1)
            case .printing: started.insert(i); observed.insert(i); done = max(done, i)
            case .pending:  observed.insert(i)                                 // queued, not started
            case .absent:   if started.contains(i) { done = max(done, i + 1) } // aged out AFTER starting
            }
        }
        return done
    }

    /// Frame a list of PropertyGetRequest elements: `[magic][uint32-LE len][JSON]`.
    private static func request(_ reqs: [[String: String]]) -> [UInt8] {
        guard let json = try? JSONSerialization.data(withJSONObject: ["PropertyGetRequests": reqs]) else { return [] }
        let len = UInt32(json.count)
        var out = magic
        out += [UInt8(len & 0xFF), UInt8((len >> 8) & 0xFF), UInt8((len >> 16) & 0xFF), UInt8((len >> 24) & 0xFF)]
        out += [UInt8](json)
        return out
    }

    /// Parse a PICL response into `["group:prop": value]`. Finds the OUTERMOST JSON object
    /// (the frame's magic/length header contains no `{`, so the first `{` starts it) and merges
    /// the response items from both `PropertyGetResponses` (targeted gets) and
    /// `GetAllPropertiesResponse` (the enumerate/subscribe reply). Returns nil if no plain JSON
    /// object is present (e.g. an LZ4-compressed BLE response, or a still-incomplete frame).
    static func parse(_ bytes: [UInt8]) -> [String: String]? {
        guard let start = bytes.firstIndex(of: UInt8(ascii: "{")) else { return nil }
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
              let obj = try? JSONSerialization.jsonObject(with: Data(bytes[start...end])) as? [String: Any]
        else { return nil }

        var map: [String: String] = [:]
        for key in ["PropertyGetResponses", "GetAllPropertiesResponse"] {
            guard let responses = obj[key] as? [[String: Any]] else { continue }
            for r in responses {
                guard let guid = r["GUID"] as? String else { continue }
                if let v = r["Value"] as? String { map[guid] = v }
                else if let n = r["Value"] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
                    map[guid] = n.boolValue ? "true" : "false"   // JSON true/false → canonical string
                }
                else if let v = r["Value"] { map[guid] = "\(v)" }
            }
        }
        return map.isEmpty ? nil : map
    }
}
