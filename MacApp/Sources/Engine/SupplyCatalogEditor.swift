import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VectorLabelCore
import VectorLabelUI

// MARK: – Editor window

/// Opens / reveals the standalone Supply Catalog editor window (from Preferences).
@MainActor
final class SupplyCatalogEditorWindow {
    static let shared = SupplyCatalogEditorWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentViewController: NSHostingController(rootView:
            SupplyCatalogEditorView(onClose: { [weak self] in self?.close() })))
        win.title = "Supply Catalog"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        // It's opened FROM the Preferences panel (which floats at .floating+1), so sit
        // one level above it — otherwise the floating Preferences window covers it.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        // Default size + persist the window frame across opens.
        win.applyVLSizing(autosaveName: "VLSupplyCatalogWindow", defaultContentSize: NSSize(width: 880, height: 640))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // The editor works on a draft and commits only via Apply, so closing
                // (Cancel / window-X) simply discards — nothing to persist here.
                if let t = self.closeObserver { NotificationCenter.default.removeObserver(t) }
                self.closeObserver = nil
                self.window = nil
            }
        }
    }

    func close() { window?.close() }
}

// MARK: – Supply catalog editor (Engine ▸ Preferences ▸ Supplies)
//
// Edits a DRAFT copy of SupplyCatalogStore: supply GROUPS (assigned to printer
// models), each with CATEGORIES of SUPPLIES, each supply with PART NUMBERS (qty /
// roll length, 90° feed rotation, optional purchase URL). Supplies drag between
// categories. Apply commits the draft to the store (which the designers pick up);
// Cancel discards it.

struct SupplyCatalogEditorView: View {
    @State private var groupIndex = 0
    @State private var selectedSupply: UUID?
    @State private var dropTarget: UUID?
    @State private var confirmRestore = false
    /// Left (categories) pane width as a fraction of the window — default 1/3, the
    /// detail pane gets 2/3. Persisted across opens (draggable divider below).
    @AppStorage("vlSupplyCatalogSplit") private var splitFraction: Double = 1.0 / 3.0
    @State private var dragStartLeft: CGFloat?
    /// The printer registry (Preferences ▸ Printers ▸ Per-Printer Settings), so a
    /// group's printers link to that list instead of being free text.
    @ObservedObject private var printerStore = PrinterModelStore.shared
    @State private var pendingDelete: PendingDelete?
    @State private var duplicating: DuplicateState?
    /// Working copy — every edit stays here until Apply; Cancel discards it.
    @State private var draft: SupplyCatalog
    let onClose: () -> Void
    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
        _draft = State(initialValue: SupplyCatalogStore.snapshot)
    }

    /// A delete the user must confirm; carries the target's name for a smart prompt.
    enum PendingDelete: Identifiable {
        case group(UUID, String), category(UUID, String), supply(UUID, String), part(UUID, UUID, String)
        var id: String {
            switch self {
            case .group(let g, _): return "g\(g)"
            case .category(let c, _): return "c\(c)"
            case .supply(let s, _): return "s\(s)"
            case .part(let s, let p, _): return "p\(s)\(p)"
            }
        }
        var name: String { switch self { case .group(_, let n), .category(_, let n), .supply(_, let n), .part(_, _, let n): return n } }
        var kind: String {
            switch self { case .group: return "supply group"; case .category: return "category"
            case .supply: return "supply"; case .part: return "part number" }
        }
    }
    /// In-flight "duplicate group" prompt.
    struct DuplicateState: Identifiable { let id = UUID(); let sourceID: UUID; let sourceName: String; var newName: String }

    var body: some View {
        VStack(spacing: 0) {
            groupBar.padding(12)
            Divider()
            if draft.groups.indices.contains(groupIndex) {
                splitPanes
            } else {
                Spacer(); Text("No supply group selected.").foregroundStyle(.secondary); Spacer()
            }
            Divider()
            footer
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear { if !draft.groups.indices.contains(groupIndex) { groupIndex = 0 } }
        .alert("Restore the factory supply catalog?", isPresented: $confirmRestore) {
            Button("Restore defaults", role: .destructive) {
                draft = .makeDefault(); groupIndex = 0; selectedSupply = nil   // applied on Apply
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every group, category, supply and part number with the built-in Brady defaults. Your customisations will be lost.")
        }
        .alert(item: $pendingDelete) { d in
            Alert(title: Text("Delete the “\(d.name)” \(d.kind)?"),
                  message: Text("This can’t be undone."),
                  primaryButton: .destructive(Text("Delete")) { performDelete(d) },
                  secondaryButton: .cancel())
        }
        .sheet(item: $duplicating) { dup in duplicateSheet(dup) }
    }

    // MARK: Apply / Cancel footer

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()
            Button("Cancel") { onClose() }                                      // revert: discard the draft
            Button("Apply") { SupplyCatalogStore.shared.replace(with: draft) }
            Button("Apply & Close") { SupplyCatalogStore.shared.replace(with: draft); onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }

    // MARK: Duplicate-group sheet

    private func duplicateSheet(_ dup: DuplicateState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Duplicate “\(dup.sourceName)”").font(.system(size: 14, weight: .semibold))
            Text("Enter a new, different name for the copied group.").font(.system(size: 12)).foregroundStyle(.secondary)
            TextField("New group name", text: Binding(
                get: { duplicating?.newName ?? "" },
                set: { duplicating?.newName = $0 }))
            HStack {
                Spacer()
                Button("Cancel") { duplicating = nil }
                Button("Duplicate") {
                    if let d = duplicating { performDuplicate(d.sourceID, newName: d.newName.trimmingCharacters(in: .whitespaces)) }
                    duplicating = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled({
                    let n = (duplicating?.newName ?? "").trimmingCharacters(in: .whitespaces)
                    return n.isEmpty || n == dup.sourceName   // must be changed
                }())
            }
        }
        .padding(18).frame(width: 340)
    }

    // MARK: Resizable 1/3 ÷ 2/3 split (persisted divider position)

    private var splitPanes: some View {
        GeometryReader { geo in
            let total = geo.size.width
            let minLeft: CGFloat = 220, minRight: CGFloat = 300, handle: CGFloat = 10
            let maxLeft = max(minLeft, total - minRight - handle)
            let leftW = min(max(total * splitFraction, minLeft), maxLeft)
            HStack(spacing: 0) {
                categoriesPane.frame(width: leftW)
                ZStack {
                    Rectangle().fill(Color.gray.opacity(0.08))
                    Divider()
                }
                .frame(width: handle)
                .contentShape(Rectangle())
                .onHover { inside in
                    if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            if dragStartLeft == nil { dragStartLeft = leftW }
                            let newLeft = min(max((dragStartLeft ?? leftW) + v.translation.width, minLeft), maxLeft)
                            splitFraction = Double(newLeft / max(total, 1))
                        }
                        .onEnded { _ in dragStartLeft = nil }
                )
                detailPane.frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Group bar

    private var groupBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Supply group").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $groupIndex) {
                    ForEach(Array(draft.groups.enumerated()), id: \.offset) { i, g in
                        Text(g.name.isEmpty ? "Untitled" : g.name).tag(i)
                    }
                }.labelsHidden().frame(width: 220)
                Button { addGroup() } label: { Image(systemName: "plus") }
                    .help("Add a supply group")
                Button {
                    let g = group
                    duplicating = DuplicateState(sourceID: g.id, sourceName: g.name, newName: g.name + " copy")
                } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate this supply group")
                Button { pendingDelete = .group(group.id, group.name) } label: { Image(systemName: "trash") }
                    .help("Delete this supply group")
                    .disabled(draft.groups.count <= 1)
                Spacer()
                Button("Restore defaults…") { confirmRestore = true }
            }
            if draft.groups.indices.contains(groupIndex) {
                HStack(spacing: 6) {
                    Text("Group name").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Group name", text: groupBinding(group.id).name).frame(width: 200)
                    Text("Printer models").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 8)
                    printerModelsMenu(group.id)
                }
            }
        }
    }

    // Printers for a group — a multi-select linked to the per-printer-settings
    // registry (Preferences ▸ Printers ▸ Per-Printer Settings), not free text.
    private func printerModelsMenu(_ gid: UUID) -> some View {
        HStack(spacing: 12) {
            if printerStore.list.models.isEmpty {
                Text("None — add in Per-Printer Settings…").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(printerStore.list.models) { m in
                Toggle(m.name, isOn: Binding(
                    get: { (draft.groups.first { $0.id == gid }?.printerModels ?? []).contains(m.name) },
                    set: { _ in toggleModel(m.name, for: gid) }))
                    .toggleStyle(.checkbox).font(.system(size: 12))
            }
        }
    }
    private func toggleModel(_ name: String, for gid: UUID) {
        guard let i = draft.groups.firstIndex(where: { $0.id == gid }) else { return }
        if let j = draft.groups[i].printerModels.firstIndex(of: name) {
            draft.groups[i].printerModels.remove(at: j)
        } else {
            draft.groups[i].printerModels.append(name)
        }
    }

    // Confirmed deletes + duplicate.
    private func performDelete(_ d: PendingDelete) {
        switch d {
        case .group(let g, _): deleteGroupByID(g)
        case .category(let c, _): deleteCategoryByID(c)
        case .supply(let s, _): deleteSupply(s)
        case .part(let s, let p, _): deletePart(s, p)
        }
    }
    private func deleteGroupByID(_ gid: UUID) {
        guard draft.groups.count > 1, let i = draft.groups.firstIndex(where: { $0.id == gid }) else { return }
        draft.groups.remove(at: i)
        groupIndex = min(groupIndex, draft.groups.count - 1)
        selectedSupply = nil
    }
    private func deleteCategoryByID(_ cid: UUID) {
        for gi in draft.groups.indices {
            guard draft.groups[gi].categories.count > 1 else { continue }
            if let ci = draft.groups[gi].categories.firstIndex(where: { $0.id == cid }) {
                draft.groups[gi].categories.remove(at: ci); return
            }
        }
    }
    private func performDuplicate(_ sourceID: UUID, newName: String) {
        guard !newName.isEmpty, let src = draft.groups.first(where: { $0.id == sourceID }) else { return }
        // Deep copy with fresh ids so the copy is independent.
        let copy = SupplyGroup(name: newName, printerModels: src.printerModels,
            categories: src.categories.map { cat in
                SupplyCategory(name: cat.name, supplies: cat.supplies.map { s in
                    Supply(name: s.name, kind: s.kind, selfLaminating: s.selfLaminating, materialFamily: s.materialFamily,
                           widthInches: s.widthInches, heightInches: s.heightInches,
                           printableWidthInches: s.printableWidthInches, printableHeightInches: s.printableHeightInches,
                           parts: s.parts.map { p in
                               SupplyPartNumber(partNumber: p.partNumber, quantityPerRoll: p.quantityPerRoll,
                                                rollLengthFeet: p.rollLengthFeet, rotate90: p.rotate90,
                                                materialLabel: p.materialLabel, overrideURL: p.overrideURL)
                           })
                })
            })
        draft.groups.append(copy)
        groupIndex = draft.groups.count - 1
        selectedSupply = nil
    }

    // Id-keyed bindings — safe against SwiftUI committing an in-flight TextField
    // edit through a stale INDEX after the array was mutated (add/delete/move/drag),
    // which crashes with "Index out of range". Each get/set looks the element up by
    // id and no-ops if it's gone.
    private func groupBinding(_ gid: UUID) -> Binding<SupplyGroup> {
        Binding(get: { draft.groups.first { $0.id == gid }
                        ?? SupplyGroup(name: "", printerModels: [], categories: []) },
                set: { v in if let i = draft.groups.firstIndex(where: { $0.id == gid }) { draft.groups[i] = v } })
    }
    private func modelsBinding(_ gid: UUID) -> Binding<String> {
        Binding(get: { (draft.groups.first { $0.id == gid }?.printerModels ?? []).joined(separator: ", ") },
                set: { v in if let i = draft.groups.firstIndex(where: { $0.id == gid }) {
                    draft.groups[i].printerModels = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } })
    }
    private func categoryNameBinding(_ cid: UUID) -> Binding<String> {
        Binding(get: { for g in draft.groups { for c in g.categories where c.id == cid { return c.name } }; return "" },
                set: { v in for gi in draft.groups.indices { for ci in draft.groups[gi].categories.indices
                    where draft.groups[gi].categories[ci].id == cid { draft.groups[gi].categories[ci].name = v; return } } })
    }
    private func supplyValue(_ sid: UUID) -> Supply? {
        for g in draft.groups { for c in g.categories { if let s = c.supplies.first(where: { $0.id == sid }) { return s } } }
        return nil
    }
    private func mutateSupply(_ sid: UUID, _ f: (inout Supply) -> Void) {
        for gi in draft.groups.indices {
            for ci in draft.groups[gi].categories.indices {
                if let si = draft.groups[gi].categories[ci].supplies.firstIndex(where: { $0.id == sid }) {
                    f(&draft.groups[gi].categories[ci].supplies[si]); return
                }
            }
        }
    }
    private func supplyBinding(_ sid: UUID) -> Binding<Supply> {
        Binding(get: { supplyValue(sid) ?? Supply(name: "", kind: .dieCut, widthInches: 1, heightInches: 1,
                                                   printableWidthInches: 1, printableHeightInches: 1, parts: []) },
                set: { v in mutateSupply(sid) { $0 = v } })
    }
    private func partBinding(_ sid: UUID, _ pid: UUID) -> Binding<SupplyPartNumber> {
        Binding(get: { supplyValue(sid)?.parts.first(where: { $0.id == pid }) ?? SupplyPartNumber(partNumber: "") },
                set: { v in mutateSupply(sid) { s in if let pi = s.parts.firstIndex(where: { $0.id == pid }) { s.parts[pi] = v } } })
    }
    // Continuous supplies: keep the tape width (width == printable width) and the
    // default length (printable height == height) in sync with the values the
    // designer/renderer actually read.
    private func contWidthBinding(_ sid: UUID) -> Binding<Double> {
        Binding(get: { supplyValue(sid)?.widthInches ?? 1 },
                set: { v in mutateSupply(sid) { $0.widthInches = v; $0.printableWidthInches = v } })
    }
    private func contLenBinding(_ sid: UUID) -> Binding<Double> {
        Binding(get: { supplyValue(sid)?.printableHeightInches ?? 1 },
                set: { v in mutateSupply(sid) { $0.printableHeightInches = v; $0.heightInches = v } })
    }

    // MARK: Categories + supplies

    private var categoriesPane: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(group.categories.enumerated()), id: \.element.id) { ci, cat in
                        categorySection(ci: ci, cat: cat)
                    }
                }
                .padding(12)
            }
            // Pinned to the bottom of the pane so it's always reachable regardless
            // of scroll position.
            Divider()
            HStack {
                Button { addCategory() } label: { Label("Add category", systemImage: "plus") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        // Arrow keys step the selection up/down through the flattened supply list.
        .focusable()
        .onMoveCommand { dir in
            switch dir { case .up: moveSelection(-1); case .down: moveSelection(1); default: break }
        }
    }

    /// Supply ids in display order across the active group's categories.
    private func orderedSupplyIDs() -> [UUID] {
        guard draft.groups.indices.contains(groupIndex) else { return [] }
        return draft.groups[groupIndex].categories.flatMap { $0.supplies.map { $0.id } }
    }
    private func moveSelection(_ delta: Int) {
        let ids = orderedSupplyIDs(); guard !ids.isEmpty else { return }
        if let cur = selectedSupply, let i = ids.firstIndex(of: cur) {
            selectedSupply = ids[min(max(i + delta, 0), ids.count - 1)]
        } else {
            selectedSupply = delta > 0 ? ids.first : ids.last
        }
    }

    private func categorySection(ci: Int, cat: SupplyCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                TextField("Category name", text: categoryNameBinding(cat.id))
                    .font(.system(size: 12, weight: .semibold)).textFieldStyle(.plain)
                Spacer()
                Button { pendingDelete = .category(cat.id, cat.name) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this category").disabled(group.categories.count <= 1)
            }
            ForEach(Array(cat.supplies.enumerated()), id: \.element.id) { si, s in
                supplyRow(ci: ci, si: si, s: s)
            }
            if cat.supplies.isEmpty {
                Text("Drag supplies here, or use “Add supply” below.").font(.system(size: 11))
                    .foregroundStyle(.tertiary).padding(.vertical, 6).padding(.leading, 22)
            }
            // Add-supply pinned to the bottom of the category box (not next to delete).
            Button { addSupply(ci: ci) } label: { Label("Add supply", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(.system(size: 11)).padding(.top, 2).padding(.leading, 20)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(dropTarget == cat.id ? Color.accentColor.opacity(0.12) : Color.gray.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(dropTarget == cat.id ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .onDrop(of: [UTType.text], isTargeted: Binding(get: { dropTarget == cat.id }, set: { dropTarget = $0 ? cat.id : nil })) { providers in
            handleDrop(providers, toCategory: cat.id)
        }
    }

    private func supplyRow(ci: Int, si: Int, s: Supply) -> some View {
        let sel = selectedSupply == s.id
        return HStack(spacing: 8) {
            Image(systemName: s.kind == .continuous ? "scroll" : "rectangle.on.rectangle")
                .foregroundStyle(.secondary).font(.system(size: 11))
            VStack(alignment: .leading, spacing: 1) {
                Text(s.name.isEmpty ? s.primaryPartNumber : s.name).font(.system(size: 12))
                Text("\(s.kind == .continuous ? "continuous" : "die-cut") · \(s.parts.count) part\(s.parts.count == 1 ? "" : "s")")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(sel ? Color.accentColor.opacity(0.20) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { selectedSupply = s.id }
        .onDrag { NSItemProvider(object: s.id.uuidString as NSString) }
        .contextMenu {
            Menu("Move to category") {
                ForEach(Array(group.categories.enumerated()), id: \.element.id) { _, c in
                    if c.id != group.categories[ci].id {
                        Button(c.name) { moveSupply(s.id, toCategory: c.id) }
                    }
                }
            }
            Button("Delete supply", role: .destructive) { pendingDelete = .supply(s.id, s.name.isEmpty ? s.primaryPartNumber : s.name) }
        }
    }

    // MARK: Detail (selected supply)

    @ViewBuilder private var detailPane: some View {
        if let sid = selectedSupply, supplyValue(sid) != nil {
            ScrollView { supplyEditor(sid: sid).padding(14) }
        } else {
            VStack { Spacer(); Text("Select a supply to edit").foregroundStyle(.secondary); Spacer() }
                .frame(maxWidth: .infinity)
        }
    }

    private func supplyEditor(sid: UUID) -> some View {
        let sB = supplyBinding(sid)
        let s = supplyValue(sid) ?? sB.wrappedValue
        let cont = s.kind == .continuous
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Supply").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(role: .destructive) { pendingDelete = .supply(sid, s.name.isEmpty ? s.primaryPartNumber : s.name) } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless)
            }
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow { Text("Name"); TextField("Name", text: sB.name) }
                GridRow {
                    Text("Type")
                    Picker("", selection: sB.kind) {
                        Text("Die-cut").tag(SupplyKind.dieCut)
                        Text("Continuous").tag(SupplyKind.continuous)
                    }.labelsHidden().pickerStyle(.segmented).frame(width: 220)
                }
                if cont {
                    // Continuous: the designer uses printableWidth (width) + printableHeight
                    // (default length). Bind those directly and mirror width/height so the
                    // edited values are the ones the canvas + renderer actually read.
                    GridRow {
                        Text("Width × Default length")
                        HStack(spacing: 6) {
                            numField(contWidthBinding(sid)); Text("×").foregroundStyle(.secondary); numField(contLenBinding(sid))
                            Text("in").foregroundStyle(.secondary)
                        }
                    }
                } else {
                    GridRow {
                        Text("Label W × H")
                        HStack(spacing: 6) {
                            numField(sB.widthInches); Text("×").foregroundStyle(.secondary); numField(sB.heightInches)
                            Text("in").foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Printable W × H")
                        HStack(spacing: 6) {
                            numField(sB.printableWidthInches); Text("×").foregroundStyle(.secondary); numField(sB.printableHeightInches)
                            Text("in").foregroundStyle(.secondary)
                        }
                    }
                }
                if !cont {
                    GridRow {
                        Text("Self-laminating")
                        Toggle("", isOn: sB.selfLaminating).labelsHidden()
                    }
                }
                GridRow { Text("Material family"); TextField("e.g. B-427", text: sB.materialFamily).frame(width: 140) }
            }
            if cont {
                Text("Continuous: the length is set at print time (“width × definable”).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Divider()
            partsEditor(sid: sid, cont: cont)
        }
    }

    private func partsEditor(sid: UUID, cont: Bool) -> some View {
        let parts = supplyValue(sid)?.parts ?? []
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Part numbers").font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { addPart(sid) } label: { Label("Add part", systemImage: "plus") }.buttonStyle(.borderless)
            }
            Text(cont ? "Each material at this width is a buy option (“Vinyl PN/50'”)."
                      : "Cartridge + bulk box appear as separate buy buttons (“PN/250”).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(parts) { p in
                partRow(sid: sid, pid: p.id, cont: cont)
            }
            if parts.isEmpty { Text("No part numbers yet.").font(.system(size: 11)).foregroundStyle(.tertiary) }
        }
    }

    private func partRow(sid: UUID, pid: UUID, cont: Bool) -> some View {
        let pB = partBinding(sid, pid)
        return VStack(spacing: 4) {
            HStack(spacing: 6) {
                TextField("Part #", text: pB.partNumber).frame(width: 130).font(.system(size: 12, design: .monospaced))
                if cont {
                    TextField("Material", text: pB.materialLabel).frame(width: 140)
                    Text("len"); numFieldOptD(pB.rollLengthFeet, width: 50); Text("ft").foregroundStyle(.secondary)
                } else {
                    Text("qty"); numFieldOptI(pB.quantityPerRoll, width: 56); Text("/roll").foregroundStyle(.secondary)
                    Toggle("Rotate 90°", isOn: pB.rotate90).toggleStyle(.checkbox).font(.system(size: 11))
                }
                Spacer()
                Button { pendingDelete = .part(sid, pid, pB.partNumber.wrappedValue.isEmpty ? "this part" : pB.partNumber.wrappedValue) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
            }
            HStack(spacing: 6) {
                Text("URL").font(.system(size: 10)).foregroundStyle(.secondary)
                TextField("Override purchase URL (blank ⇒ Brady part-number search)", text: pB.overrideURL)
                    .font(.system(size: 11))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(0.07)))
    }

    // MARK: Number fields

    private func numField(_ b: Binding<Double>) -> some View {
        // Clamp on commit so a supply can never get a zero / negative / NaN dimension
        // (which yields a degenerate canvas and a 0-pixel render that silently fails),
        // nor an absurdly large one (which used to overflow Int at pixel-conversion
        // time and crash the renderer). 60in is well beyond any real Brady label.
        let clamped = Binding<Double>(get: { b.wrappedValue },
                                      set: { b.wrappedValue = ($0.isFinite && $0 > 0) ? min($0, 60.0) : 0.05 })
        return TextField("", value: clamped, format: .number).frame(width: 54).multilineTextAlignment(.trailing)
    }
    private func numFieldOptI(_ b: Binding<Int?>, width: CGFloat) -> some View {
        TextField("", value: Binding(get: { b.wrappedValue ?? 0 }, set: { b.wrappedValue = $0 <= 0 ? nil : $0 }), format: .number)
            .frame(width: width).multilineTextAlignment(.trailing)
    }
    private func numFieldOptD(_ b: Binding<Double?>, width: CGFloat) -> some View {
        TextField("", value: Binding(get: { b.wrappedValue ?? 0 }, set: { b.wrappedValue = $0 <= 0 ? nil : $0 }), format: .number)
            .frame(width: width).multilineTextAlignment(.trailing)
    }

    // MARK: Model access + mutations

    private var group: SupplyGroup {
        draft.groups.indices.contains(groupIndex) ? draft.groups[groupIndex]
            : SupplyGroup(name: "", printerModels: [], categories: [])
    }

    private func addGroup() {
        draft.groups.append(SupplyGroup(name: "New group", printerModels: [],
            categories: [SupplyCategory(name: "Category", supplies: [])]))
        groupIndex = draft.groups.count - 1
        selectedSupply = nil
    }
    private func deleteGroup() {
        guard draft.groups.count > 1, draft.groups.indices.contains(groupIndex) else { return }
        draft.groups.remove(at: groupIndex)
        groupIndex = min(groupIndex, draft.groups.count - 1)
        selectedSupply = nil
    }
    private func addCategory() {
        guard draft.groups.indices.contains(groupIndex) else { return }
        draft.groups[groupIndex].categories.append(SupplyCategory(name: "New category", supplies: []))
    }
    private func deleteCategory(ci: Int) {
        guard draft.groups.indices.contains(groupIndex),
              draft.groups[groupIndex].categories.count > 1,
              draft.groups[groupIndex].categories.indices.contains(ci) else { return }
        draft.groups[groupIndex].categories.remove(at: ci)
    }
    private func addSupply(ci: Int) {
        guard draft.groups.indices.contains(groupIndex),
              draft.groups[groupIndex].categories.indices.contains(ci) else { return }
        let s = Supply(name: "New supply", kind: .dieCut, widthInches: 1, heightInches: 1,
                       printableWidthInches: 1, printableHeightInches: 1,
                       parts: [SupplyPartNumber(partNumber: "")])
        draft.groups[groupIndex].categories[ci].supplies.append(s)
        selectedSupply = s.id
    }
    private func deleteSupply(_ sid: UUID) {
        for gi in draft.groups.indices {
            for ci in draft.groups[gi].categories.indices {
                if let si = draft.groups[gi].categories[ci].supplies.firstIndex(where: { $0.id == sid }) {
                    draft.groups[gi].categories[ci].supplies.remove(at: si)
                    if selectedSupply == sid { selectedSupply = nil }
                    return
                }
            }
        }
    }
    private func moveSupply(_ id: UUID, toCategory cid: UUID) {
        guard draft.groups.indices.contains(groupIndex) else { return }
        var cats = draft.groups[groupIndex].categories
        var moved: Supply?
        for ci in cats.indices {
            if let si = cats[ci].supplies.firstIndex(where: { $0.id == id }) { moved = cats[ci].supplies.remove(at: si); break }
        }
        guard let supply = moved, let dci = cats.firstIndex(where: { $0.id == cid }) else { return }
        cats[dci].supplies.append(supply)
        draft.groups[groupIndex].categories = cats
        selectedSupply = id
    }
    private func addPart(_ sid: UUID) { mutateSupply(sid) { $0.parts.append(SupplyPartNumber(partNumber: "")) } }
    private func deletePart(_ sid: UUID, _ pid: UUID) { mutateSupply(sid) { $0.parts.removeAll { $0.id == pid } } }
    private func handleDrop(_ providers: [NSItemProvider], toCategory cid: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let str = obj as? String, let id = UUID(uuidString: str) else { return }
            DispatchQueue.main.async { moveSupply(id, toCategory: cid) }
        }
        return true
    }
}
