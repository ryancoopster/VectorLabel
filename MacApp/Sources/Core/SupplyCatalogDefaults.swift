import Foundation

// MARK: – Factory-default supply catalog
//
// The shipped seed. Generated in code (not a bundled JSON) so it's easy to curate
// and never drifts from a resource. Users edit a saved copy in Application Support;
// "Restore defaults" rebuilds from here.
//
// Data sources, in priority order:
//   1. The previous hand-tuned catalog (BradyCatalog.json) — its geometry, printable
//      areas, rotation and quantities are PRESERVED verbatim for the part numbers it
//      had, so existing designs/templates and the unit tests are unaffected.
//   2. The seven Brady M6/M7 product PDFs the user supplied (2026-06-17) — used to
//      ADD new sizes/families. Sizes + part numbers are reliable; printable areas
//      were not captured for the flat (non-self-laminating) families, where the
//      printable area equals the full label, so that default is correct. Continuous
//      tapes were scroll-clipped in the PDFs, so only confirmed widths are seeded.
// Everything here is editable in Engine ▸ Preferences ▸ Supplies.

extension SupplyCatalog {

    /// One flat seed row, grouped into `Supply` objects by geometry below.
    fileprivate struct Row {
        let cat: String
        let kind: SupplyKind
        let selfLam: Bool
        let material: String        // family, e.g. "B-427"
        let w: Double, h: Double, pw: Double, ph: Double
        let pn: String
        let qty: Int?
        let lenFt: Double?
        let matLabel: String        // shown on continuous buy buttons
        init(_ cat: String, _ kind: SupplyKind, selfLam: Bool = false, material: String,
             _ w: Double, _ h: Double, _ pw: Double, _ ph: Double,
             _ pn: String, qty: Int? = nil, lenFt: Double? = nil, matLabel: String = "") {
            self.cat = cat; self.kind = kind; self.selfLam = selfLam; self.material = material
            self.w = w; self.h = h; self.pw = pw; self.ph = ph
            self.pn = pn; self.qty = qty; self.lenFt = lenFt; self.matLabel = matLabel
        }
    }

    public static func makeDefault() -> SupplyCatalog {
        let WRAP = "Wire & Cable Wraps (Self-Laminating)"
        let POLY = "Multi-Purpose Polyester Labels"
        let CLEAR = "Clear Polyester Labels"
        let PANEL = "Raised Panel Labels"
        let CONT = "Continuous Tapes"

        let rows: [Row] = [
            // ── Self-laminating vinyl wraps (B-427) — geometry preserved from the old
            //    catalog; same-size cartridge / bulk-box parts consolidated per size. ──
            // 1"×1.5" wrap: M6 cartridge (250/roll) + BM bulk box (2500/box).
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.0, 1.5, 1.0, 0.5, "M6-31-427", qty: 250),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.0, 1.5, 1.0, 0.5, "BM-31-427", qty: 2500),
            // 1"×2.5" wrap (distinct size — was wrongly merged with 1"×1.5").
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.0, 2.5, 1.0, 0.75, "M6-21-427", qty: 250),
            // 1.5"×1.5" wrap: M6 cartridge (250/roll) + BM bulk box (1000/box).
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.5, 1.5, 1.5, 0.5, "M6-32-427", qty: 250),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.5, 1.5, 1.5, 0.5, "BM-32-427", qty: 1000),
            // 1.5"×4" wrap: M6 cartridge (100/roll) + BM bulk box.
            // (M6-109-427 dropped — it was derived from the M710-only M7-109-427.)
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.5, 4.0, 1.5, 1.5, "M6-33-427", qty: 100),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.5, 4.0, 1.5, 1.5, "BM-33-427"),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 0.5, 1.0, 0.5, 0.25, "M6-11-427", qty: 250),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 0.75, 1.0, 0.75, 0.25, "M6-17-427", qty: 250),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.0, 1.0, 1.0, 0.375, "M6-19-427", qty: 250),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 2.0, 2.0, 2.0, 1.0, "M6-34-427", qty: 100),
            // New wrap sizes from the wrap PDF (printable from the PDF; qty not shown).
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 0.25, 1.5, 0.25, 0.5, "M6-28-427"),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 0.5, 1.5, 0.5, 0.5, "M6-29-427"),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 0.75, 1.5, 0.75, 0.5, "M6-30-427"),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.0, 4.0, 1.0, 1.0, "M6-23-427"),
            Row(WRAP, .dieCut, selfLam: true, material: "B-427", 1.75, 1.5, 1.75, 0.5, "M6-88-427"),

            // ── Multi-purpose polyester die-cut labels (flat: printable = full label).
            //    B-423 (harsh), B-483 (ultra-aggressive), B-422 (PermaShield). ──
            Row(POLY, .dieCut, material: "B-423", 0.25, 0.25, 0.25, 0.25, "M6-1-423"),
            Row(POLY, .dieCut, material: "B-423", 0.375, 0.375, 0.375, 0.375, "M6-3-423"),
            Row(POLY, .dieCut, material: "B-423", 0.4, 0.4, 0.4, 0.4, "M6-4-423"),
            Row(POLY, .dieCut, material: "B-423", 1.0, 1.0, 1.0, 1.0, "M6-19-423"),
            Row(POLY, .dieCut, material: "B-423", 1.0, 2.0, 1.0, 2.0, "M6-20-423"),
            Row(POLY, .dieCut, material: "B-423", 2.0, 0.25, 2.0, 0.25, "M6-2-423"),
            Row(POLY, .dieCut, material: "B-423", 3.0, 1.0, 3.0, 1.0, "M6-22-423"),
            Row(POLY, .dieCut, material: "B-483", 1.0, 0.375, 1.0, 0.375, "M6-16-483"),
            Row(POLY, .dieCut, material: "B-483", 1.0, 0.5, 1.0, 0.5, "M6-17-483"),
            Row(POLY, .dieCut, material: "B-483", 1.5, 0.5, 1.5, 0.5, "M6-29-483"),
            Row(POLY, .dieCut, material: "B-483", 1.5, 0.75, 1.5, 0.75, "M6-30-483"),
            Row(POLY, .dieCut, material: "B-483", 1.5, 1.5, 1.5, 1.5, "M6-32-483"),
            Row(POLY, .dieCut, material: "B-483", 4.0, 1.0, 4.0, 1.0, "M6-23-483"),
            Row(POLY, .dieCut, material: "B-483", 4.0, 1.9, 4.0, 1.9, "M6-38-483"),
            Row(POLY, .dieCut, material: "B-422", 1.0, 0.5, 1.0, 0.5, "M6-17-422", qty: nil),
            Row(POLY, .dieCut, material: "B-422", 2.0, 1.0, 2.0, 1.0, "M6-20-422", qty: 100),
            Row(POLY, .dieCut, material: "B-422", 2.75, 1.25, 2.75, 1.25, "M6-26-422"),
            Row(POLY, .dieCut, material: "B-422", 3.0, 1.65, 3.0, 1.65, "M6-50-422"),

            // ── Clear polyester die-cut labels (B-430; flat, printable = full). ──
            Row(CLEAR, .dieCut, material: "B-430", 1.0, 0.375, 1.0, 0.375, "M6-98-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.0, 3.0, 1.0, 3.0, "M6-22-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.5, 0.25, 1.5, 0.25, "M6-28-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.5, 0.75, 1.5, 0.75, "M6-30-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.9, 0.6, 1.9, 0.6, "M6-52-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.9, 1.0, 1.9, 1.0, "M6-78-430"),
            Row(CLEAR, .dieCut, material: "B-430", 1.25, 2.75, 1.25, 2.75, "M6-198-430"),
            Row(CLEAR, .dieCut, material: "B-430", 3.0, 1.9, 3.0, 1.9, "M6-37-430"),

            // ── Raised panel die-cut labels (B-593; flat, printable = full). The two
            //    M610/M611-compatible sizes (the M7-…-593 variants are M710-only).
            //    Box of 100. ──
            Row(PANEL, .dieCut, material: "B-593", 1.0, 2.0, 1.0, 2.0, "M6-173-593", qty: 100),
            Row(PANEL, .dieCut, material: "B-593", 1.0, 4.0, 1.0, 4.0, "M6-174-593", qty: 100),

            // ── Continuous tapes — grouped by WIDTH; each material is a buy option.
            //    Length is user-set ("width × definable"); 50 ft rolls. ──
            Row(CONT, .continuous, material: "B-483", 0.25, 1.0, 0.25, 1.0, "M6C-250-483", lenFt: 50, matLabel: "Polyester"),
            Row(CONT, .continuous, material: "B-422", 0.5, 1.0, 0.5, 1.0, "M6C-500-422", lenFt: 50, matLabel: "Polyester"),
            Row(CONT, .continuous, material: "B-595", 0.5, 1.0, 0.5, 1.0, "M6C-500-595", lenFt: 50, matLabel: "Vinyl"),
            Row(CONT, .continuous, material: "B-422", 1.0, 1.0, 1.0, 1.0, "M6C-1000-422", lenFt: 50, matLabel: "Polyester"),
            Row(CONT, .continuous, material: "B-430", 1.0, 1.0, 1.0, 1.0, "M6C-1000-430", lenFt: 50, matLabel: "Clear polyester"),
            Row(CONT, .continuous, material: "B-430", 1.9, 1.0, 1.9, 1.0, "M6C-1900-430", lenFt: 50, matLabel: "Clear polyester"),
            Row(CONT, .continuous, material: "B-595", 2.0, 1.0, 2.0, 1.0, "M6C-2000-595", lenFt: 50, matLabel: "Vinyl"),
        ]

        // Group rows into supplies. Die-cut: one supply per (category, w, h, pw, ph).
        // Continuous: one supply per (category, width) — length is user-set, so all
        // materials of a width share one row with several buy options.
        let catOrder = [WRAP, POLY, CLEAR, PANEL, CONT]
        var categories: [SupplyCategory] = []
        for catName in catOrder {
            let catRows = rows.filter { $0.cat == catName }
            var supplyKeys: [String] = []                 // preserve first-seen order
            var byKey: [String: [Row]] = [:]
            for r in catRows {
                let key = r.kind == .continuous
                    ? "c|\(r.w)"
                    : "d|\(r.w)|\(r.h)|\(r.pw)|\(r.ph)"
                if byKey[key] == nil { byKey[key] = []; supplyKeys.append(key) }
                byKey[key]!.append(r)
            }
            var supplies: [Supply] = []
            for key in supplyKeys {
                let group = byKey[key]!
                let r0 = group[0]
                let parts = group.map {
                    SupplyPartNumber(partNumber: $0.pn, quantityPerRoll: $0.qty,
                                     rollLengthFeet: $0.lenFt, materialLabel: $0.matLabel)
                }
                let name = r0.kind == .continuous
                    ? "\(fmtIn(r0.w)) continuous"
                    : "\(fmtIn(r0.w)) × \(fmtIn(r0.h))"
                supplies.append(Supply(
                    name: name, kind: r0.kind, selfLaminating: r0.selfLam,
                    materialFamily: r0.material, widthInches: r0.w, heightInches: r0.h,
                    printableWidthInches: r0.pw, printableHeightInches: r0.ph, parts: parts))
            }
            categories.append(SupplyCategory(name: catName, supplies: supplies))
        }

        let group = SupplyGroup(name: "Brady M6", printerModels: ["M610", "M611"],
                                categories: categories)
        return SupplyCatalog(version: 3, groups: [group, brotherPTouchGroup()],
                             coreEquivalences: ["109-427": "33-427"])
    }

    /// The Brother P-touch supply group: continuous TZe laminated tapes in every
    /// supported width. These printers have NO die-cut supplies — only continuous
    /// tape — and the printable WIDTH (across the head) is less than the tape width
    /// because each width has an unprintable margin on both sides of the 128-pin,
    /// 180-DPI head (printable px = `128 - margin*2` → inches = px / 180). Length is
    /// user-set at print time. Part numbers are the default black-on-white laminated
    /// SKUs where known and are editable in Preferences ▸ Supplies.
    static func brotherPTouchGroup() -> SupplyGroup {
        // (tape mm, printable pins per BrotherPT.printWidth, default part number)
        let tapes: [(mm: Double, pins: Int, pn: String)] = [
            (3.5, 24,  "TZe-3.5mm"),
            (6,   32,  "TZe-211"),
            (9,   50,  "TZe-221"),
            (12,  70,  "TZe-231"),
            (18,  112, "TZe-241"),
            (24,  128, "TZe-251"),
        ]
        // Sizes are rounded to 2 decimals for a clean display in the supply picker
        // (the exact tape is recovered by the encoder's nearest-printable-width snap,
        // so the small rounding doesn't affect which tape is selected). TZe tapes are
        // laminated → marked self-laminating so the type reads "Continuous Self
        // Laminating" (the clear-wrap overlay is gated to die-cut self-laminating).
        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        let supplies: [Supply] = tapes.map { t in
            return Supply(
                name: "\(fmtMM(t.mm)) continuous", kind: .continuous, selfLaminating: true,
                materialFamily: "TZe", widthInches: r2(t.mm / 25.4), heightInches: 1.0,
                printableWidthInches: r2(Double(t.pins) / 180.0), printableHeightInches: 1.0,
                parts: [SupplyPartNumber(partNumber: t.pn, rollLengthFeet: 26.2,
                                         materialLabel: "Laminated")])
        }
        return SupplyGroup(name: "Brother P-touch",
                           printerModels: ["PT-E550W", "PT-P750W", "PT-E560BT"],
                           categories: [SupplyCategory(name: "TZe Laminated Tapes", supplies: supplies)])
    }

    private static func fmtIn(_ v: Double) -> String {
        (v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)) + "\""
    }

    private static func fmtMM(_ v: Double) -> String {
        (v == v.rounded() ? "\(Int(v))" : String(format: "%g", v)) + " mm"
    }
}
