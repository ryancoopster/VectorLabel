import Foundation

// MARK: – Editable supply catalog model
//
// The supply catalog used to be a fixed table (BradyCatalog.json + JS `BL`
// mirrors). It is now a user-editable structure stored in Application Support
// (SupplyCatalogStore) so each printer model can have its own supplies:
//
//   SupplyCatalog
//     └─ SupplyGroup           (a named set of supplies, assigned to printer models)
//          └─ SupplyCategory   (user-named, reorderable; supplies drag between them)
//               └─ Supply       (a label + canvas size; die-cut OR continuous)
//                    └─ SupplyPartNumber  (the orderable SKUs that print this size)
//
// `BradyCatalog` is kept as a thin façade over the active catalog so the print /
// match / render pipeline (which looks supplies up by part number) is unchanged.

/// How a supply is cut/sized: pre-cut die-cut labels (fixed height) vs a
/// continuous tape whose label length the user sets at print time.
public enum SupplyKind: String, Codable, Hashable {
    case dieCut
    case continuous
}

/// One purchasable SKU (part number) that prints a given supply size. A single
/// supply can have several — e.g. a cartridge + a bulk box (die-cut), or the same
/// tape width in vinyl + polyester (continuous).
public struct SupplyPartNumber: Codable, Hashable, Identifiable {
    public var id: UUID
    /// Brady part number, e.g. "M6-32-427" or "M6C-1000-595".
    public var partNumber: String
    /// Die-cut: labels per roll/cartridge (shown as "PN/250"). nil ⇒ unknown.
    public var quantityPerRoll: Int?
    /// Continuous: roll length in feet (shown as "Vinyl PN/50'"). nil ⇒ unknown.
    public var rollLengthFeet: Double?
    /// Die-cut: Brady feeds this label rotated 90° on the roll, so the printed
    /// raster is rotated to match (drives BradyCatalog.feedRotationDeg → the
    /// renderer's feedRotation). Ignored for continuous.
    public var rotate90: Bool
    /// Material/finish label for display on continuous buy buttons, e.g. "Vinyl",
    /// "Polyester", "Clear polyester". "" ⇒ fall back to the supply's material.
    public var materialLabel: String
    /// Optional purchase URL. "" ⇒ open a Brady part-number search (buyTerm).
    public var overrideURL: String

    public init(partNumber: String, quantityPerRoll: Int? = nil, rollLengthFeet: Double? = nil,
                rotate90: Bool = false, materialLabel: String = "", overrideURL: String = "",
                id: UUID = UUID()) {
        self.id = id
        self.partNumber = partNumber
        self.quantityPerRoll = quantityPerRoll
        self.rollLengthFeet = rollLengthFeet
        self.rotate90 = rotate90
        self.materialLabel = materialLabel
        self.overrideURL = overrideURL
    }

    // Tolerate hand-edited / older JSON missing the id or optional fields.
    private enum CodingKeys: String, CodingKey {
        case id, partNumber, quantityPerRoll, rollLengthFeet, rotate90, materialLabel, overrideURL
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        partNumber = try c.decode(String.self, forKey: .partNumber)
        quantityPerRoll = try? c.decodeIfPresent(Int.self, forKey: .quantityPerRoll)
        rollLengthFeet = try? c.decodeIfPresent(Double.self, forKey: .rollLengthFeet)
        rotate90 = (try? c.decode(Bool.self, forKey: .rotate90)) ?? false
        materialLabel = (try? c.decode(String.self, forKey: .materialLabel)) ?? ""
        overrideURL = (try? c.decode(String.self, forKey: .overrideURL)) ?? ""
    }
}

/// A label + canvas size the user designs against. Die-cut supplies have a fixed
/// height; continuous supplies have a user-set length ("width × definable").
public struct Supply: Codable, Hashable, Identifiable {
    public var id: UUID
    /// Display name in the picker, e.g. "1.5\" × 1.5\" wrap" or "1\" continuous".
    public var name: String
    public var kind: SupplyKind
    /// Self-laminating (clear over-laminate tail) — affects the type descriptor.
    public var selfLaminating: Bool
    /// Brady material family for grouping/labelling, e.g. "B-427", "B-595". "" ok.
    public var materialFamily: String
    public var widthInches: Double
    /// Die-cut: physical label height. Continuous: a sensible default length
    /// (the user overrides it at print time).
    public var heightInches: Double
    public var printableWidthInches: Double
    public var printableHeightInches: Double
    public var parts: [SupplyPartNumber]

    public init(name: String, kind: SupplyKind, selfLaminating: Bool = false,
                materialFamily: String = "", widthInches: Double, heightInches: Double,
                printableWidthInches: Double, printableHeightInches: Double,
                parts: [SupplyPartNumber], id: UUID = UUID()) {
        self.id = id
        self.name = name
        self.kind = kind
        self.selfLaminating = selfLaminating
        self.materialFamily = materialFamily
        self.widthInches = widthInches
        self.heightInches = heightInches
        self.printableWidthInches = printableWidthInches
        self.printableHeightInches = printableHeightInches
        self.parts = parts
    }

    public var isContinuous: Bool { kind == .continuous }
    /// The part number used as this supply's stable identity in templates /
    /// designs (`specN`) — the first part. Empty supplies fall back to the name.
    public var primaryPartNumber: String { parts.first?.partNumber ?? name }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, selfLaminating, materialFamily, widthInches, heightInches
        case printableWidthInches, printableHeightInches, parts
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        kind = (try? c.decode(SupplyKind.self, forKey: .kind)) ?? .dieCut
        selfLaminating = (try? c.decode(Bool.self, forKey: .selfLaminating)) ?? false
        materialFamily = (try? c.decode(String.self, forKey: .materialFamily)) ?? ""
        widthInches = try c.decode(Double.self, forKey: .widthInches)
        heightInches = try c.decode(Double.self, forKey: .heightInches)
        printableWidthInches = (try? c.decode(Double.self, forKey: .printableWidthInches)) ?? widthInches
        printableHeightInches = (try? c.decode(Double.self, forKey: .printableHeightInches)) ?? heightInches
        parts = (try? c.decode([SupplyPartNumber].self, forKey: .parts)) ?? []
    }
}

/// A user-named grouping of supplies within a group. Supplies can be dragged
/// between categories in the editor.
public struct SupplyCategory: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var supplies: [Supply]

    public init(name: String, supplies: [Supply], id: UUID = UUID()) {
        self.id = id; self.name = name; self.supplies = supplies
    }
    private enum CodingKeys: String, CodingKey { case id, name, supplies }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        supplies = (try? c.decode([Supply].self, forKey: .supplies)) ?? []
    }
}

/// A set of supplies assigned to one or more printer models (e.g. M610 + M611
/// share one group). Adding a new printer type means adding a new group.
public struct SupplyGroup: Codable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    /// Printer models this group serves, e.g. ["M610", "M611"] (matched against
    /// PrinterStatusFile.model, case-insensitively).
    public var printerModels: [String]
    public var categories: [SupplyCategory]

    public init(name: String, printerModels: [String], categories: [SupplyCategory], id: UUID = UUID()) {
        self.id = id; self.name = name; self.printerModels = printerModels; self.categories = categories
    }
    private enum CodingKeys: String, CodingKey { case id, name, printerModels, categories }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        printerModels = (try? c.decode([String].self, forKey: .printerModels)) ?? []
        categories = (try? c.decode([SupplyCategory].self, forKey: .categories)) ?? []
    }

    public func serves(model: String) -> Bool {
        let m = model.trimmingCharacters(in: .whitespaces).lowercased()
        return printerModels.contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == m }
    }
}

// MARK: – Deep copy with fresh ids (import / duplicate)
//
// Reconstructing through the initializers (which default `id: UUID()`) yields a copy
// whose ids can't collide with an existing group/category/supply/part — required when
// importing a file or duplicating, since UUIDs are SwiftUI identity + match keys.

public extension SupplyPartNumber {
    func withFreshID() -> SupplyPartNumber {
        SupplyPartNumber(partNumber: partNumber, quantityPerRoll: quantityPerRoll,
                         rollLengthFeet: rollLengthFeet, rotate90: rotate90,
                         materialLabel: materialLabel, overrideURL: overrideURL)
    }
}
public extension Supply {
    func withFreshIDs() -> Supply {
        Supply(name: name, kind: kind, selfLaminating: selfLaminating, materialFamily: materialFamily,
               widthInches: widthInches, heightInches: heightInches,
               printableWidthInches: printableWidthInches, printableHeightInches: printableHeightInches,
               parts: parts.map { $0.withFreshID() })
    }
}
public extension SupplyCategory {
    func withFreshIDs() -> SupplyCategory {
        SupplyCategory(name: name, supplies: supplies.map { $0.withFreshIDs() })
    }
}
public extension SupplyGroup {
    func withFreshIDs() -> SupplyGroup {
        SupplyGroup(name: name, printerModels: printerModels, categories: categories.map { $0.withFreshIDs() })
    }
}

// MARK: – Sanitize untrusted supplies (import / on-disk load)
//
// A hand-edited or corrupt .vlsupply / SupplyCatalog.json can carry a 0, negative, NaN,
// or absurd dimension, or a blank part number. The render path clamps geometry so this
// never crashes, but it would still surface a degenerate 1px label and a broken buy
// button with no feedback. Clamp on every untrusted ingress — the editor's own numField
// applies the same intent for interactively-typed values, which import otherwise bypasses.

public extension Supply {
    /// Clamp dimensions to a finite, positive, sane range and drop blank part numbers.
    /// Preserves ids (so it is safe on the on-disk load path); pair with `withFreshIDs()`
    /// on import.
    func sanitized() -> Supply {
        func dim(_ v: Double, _ fallback: Double) -> Double {
            guard v.isFinite, v > 0 else { return fallback }
            return min(v, 60.0)   // 60in ceiling — larger than any real Brady/Brother supply
        }
        let w = dim(widthInches, 1), h = dim(heightInches, 1)
        return Supply(name: name, kind: kind, selfLaminating: selfLaminating, materialFamily: materialFamily,
                      widthInches: w, heightInches: h,
                      printableWidthInches: dim(printableWidthInches, w),
                      printableHeightInches: dim(printableHeightInches, h),
                      parts: parts.filter { !$0.partNumber.trimmingCharacters(in: .whitespaces).isEmpty },
                      id: id)
    }
}
public extension SupplyCategory {
    func sanitized() -> SupplyCategory {
        SupplyCategory(name: name, supplies: supplies.map { $0.sanitized() }, id: id)
    }
}
public extension SupplyGroup {
    func sanitized() -> SupplyGroup {
        SupplyGroup(name: name, printerModels: printerModels,
                    categories: categories.map { $0.sanitized() }, id: id)
    }
}

/// A portable supply export — exactly one of `group` / `category` is set. A versioned
/// envelope so import can validate the file is ours and the format can evolve.
public struct SupplyExport: Codable {
    public static let formatTag = "vectorlabel-supply"
    /// Current export schema version. Import rejects files written by a newer build
    /// (version > currentVersion) so an incompatible future format fails loudly instead
    /// of being silently best-effort-decoded.
    public static let currentVersion = 1
    public var format: String
    public var version: Int
    public var group: SupplyGroup?
    public var category: SupplyCategory?
    public init(group: SupplyGroup? = nil, category: SupplyCategory? = nil) {
        self.format = SupplyExport.formatTag; self.version = SupplyExport.currentVersion
        self.group = group; self.category = category
    }
}

/// The whole editable catalog: every group plus the bulk-box ↔ cartridge core
/// equivalence map used by part-number matching.
public struct SupplyCatalog: Codable, Hashable {
    /// Schema version, for future migrations.
    public var version: Int
    public var groups: [SupplyGroup]
    /// Part-number "core" equivalences (e.g. "109-427" → "33-427") so a bulk box
    /// matches its cartridge. Mirrors the old BradyCatalog.json `coreEquivalences`.
    public var coreEquivalences: [String: String]

    public init(version: Int = 1, groups: [SupplyGroup], coreEquivalences: [String: String]) {
        self.version = version; self.groups = groups; self.coreEquivalences = coreEquivalences
    }
    private enum CodingKeys: String, CodingKey { case version, groups, coreEquivalences }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        version = (try? c.decode(Int.self, forKey: .version)) ?? 1
        groups = (try? c.decode([SupplyGroup].self, forKey: .groups)) ?? []
        coreEquivalences = (try? c.decode([String: String].self, forKey: .coreEquivalences)) ?? [:]
    }

    /// Flatten every part across every group to (supply, part) pairs — used by the
    /// BradyCatalog façade to resolve any part number the printer might report.
    public func allSupplyParts() -> [(supply: Supply, part: SupplyPartNumber)] {
        var out: [(Supply, SupplyPartNumber)] = []
        for g in groups { for cat in g.categories { for s in cat.supplies { for p in s.parts { out.append((s, p)) } } } }
        return out
    }

    /// The group serving a printer model, or the first group as a fallback.
    public func group(forModel model: String) -> SupplyGroup? {
        groups.first { $0.serves(model: model) } ?? groups.first
    }

    /// Non-destructively upgrade a loaded catalog. User-editable groups are ALWAYS
    /// preserved; only the auto-generated factory "Brother P-touch" group (matched by its
    /// EXACT name) is touched. v1→v2 ADDS that group if no Brother-serving group exists.
    /// v2→v3 REPLACES only the factory-named group with the current factory definition
    /// (corrected sizes + self-laminating type) so an existing install picks up the fix
    /// without a manual "Restore defaults" — a user-authored OR renamed Brother group
    /// survives untouched (the earlier code removed every group serving a Brother model,
    /// destroying user edits). v3→v4 ADDS the full raised-panel size set to the M610/M611
    /// group (a prior build dropped 2 of the 4) — additive + idempotent, by part number,
    /// so user edits/customizations survive. No-op for v4+.
    public func migrated() -> SupplyCatalog {
        guard version < 4 else { return self }
        var c = self
        let brotherModels: Set<String> = ["pt-e550w", "pt-p750w", "pt-e560bt"]
        func servesBrother(_ g: SupplyGroup) -> Bool {
            g.printerModels.contains { brotherModels.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        let factoryName = SupplyCatalog.brotherPTouchGroup().name
        func isFactoryGroup(_ g: SupplyGroup) -> Bool {
            g.name.trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(factoryName) == .orderedSame
        }
        if c.version < 2 {
            if !c.groups.contains(where: servesBrother) { c.groups.append(SupplyCatalog.brotherPTouchGroup()) }
        }
        if c.version < 3 {
            // Refresh ONLY the auto-generated factory group (by exact name), never every
            // Brother-serving group — a user's own / renamed group must survive.
            c.groups.removeAll(where: isFactoryGroup)
            c.groups.append(SupplyCatalog.brotherPTouchGroup())
        }
        if c.version < 4 {
            // ADD any raised-panel sizes the M610/M611 group is missing (a prior build
            // shipped only 2 of the 4). ADDITIVE + idempotent — matched by part number,
            // so it never removes or overwrites a user's own supplies/edits.
            let panelCat = "Raised Panel Labels"
            let panelDefaults = SupplyCatalog.makeDefault().groups
                .flatMap { $0.categories }
                .first { $0.name.caseInsensitiveCompare(panelCat) == .orderedSame }?
                .supplies ?? []
            let m6Models: Set<String> = ["m610", "m611"]
            for gi in c.groups.indices where c.groups[gi].printerModels.contains(where: {
                m6Models.contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) {
                let existing = Set(c.groups[gi].categories
                    .flatMap { $0.supplies.flatMap { $0.parts.map { $0.partNumber.uppercased() } } })
                let missing = panelDefaults.filter { s in
                    !s.parts.contains { existing.contains($0.partNumber.uppercased()) } }
                guard !missing.isEmpty else { continue }
                if let ci = c.groups[gi].categories.firstIndex(where: {
                    $0.name.caseInsensitiveCompare(panelCat) == .orderedSame }) {
                    c.groups[gi].categories[ci].supplies.append(contentsOf: missing)
                } else {
                    c.groups[gi].categories.append(SupplyCategory(name: panelCat, supplies: missing))
                }
            }
        }
        c.version = 4
        return c
    }

    /// Clamp every supply to a sane range (see `Supply.sanitized()`). Applied on the
    /// on-disk load path so a hand-edited / corrupt `SupplyCatalog.json` surfaces clamped
    /// sizes instead of degenerate 1px labels and broken buy buttons — independent of the
    /// version-gated `migrated()` (which no-ops for an already-current catalog).
    public func sanitizedCatalog() -> SupplyCatalog {
        var c = self
        c.groups = groups.map { $0.sanitized() }
        return c
    }
}
