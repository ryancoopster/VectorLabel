import SwiftUI
import AppKit
import UniformTypeIdentifiers
import VectorLabelCore

// MARK: – Editor window

/// Opens / reveals the standalone Supply Catalog editor window (from Preferences).
@MainActor
final class SupplyCatalogEditorWindow {
    static let shared = SupplyCatalogEditorWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentViewController: NSHostingController(rootView: SupplyCatalogEditorView()))
        win.title = "Supply Catalog"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        // It's opened FROM the Preferences panel (which floats at .floating+1), so sit
        // one level above it — otherwise the floating Preferences window covers it.
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        win.setContentSize(NSSize(width: 880, height: 640))
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                // Flush any debounced edits immediately when the editor closes.
                SupplyCatalogStore.shared.save()
                if let t = self.closeObserver { NotificationCenter.default.removeObserver(t) }
                self.closeObserver = nil
                self.window = nil
            }
        }
    }
}

// MARK: – Supply catalog editor (Engine ▸ Preferences ▸ Supplies)
//
// Edits SupplyCatalogStore.shared: supply GROUPS (assigned to printer models),
// each with CATEGORIES of SUPPLIES, each supply with PART NUMBERS (qty / roll
// length, 90° feed rotation, optional purchase URL). Supplies drag between
// categories. All edits auto-persist (the store debounces a disk write), so the
// designers pick them up the next time they open.

struct SupplyCatalogEditorView: View {
    @ObservedObject private var store = SupplyCatalogStore.shared
    @State private var groupIndex = 0
    @State private var selectedSupply: UUID?
    @State private var dropTarget: UUID?
    @State private var confirmRestore = false

    var body: some View {
        VStack(spacing: 0) {
            groupBar.padding(12)
            Divider()
            if store.catalog.groups.indices.contains(groupIndex) {
                HSplitView {
                    categoriesPane.frame(minWidth: 330, idealWidth: 380)
                    detailPane.frame(minWidth: 340)
                }
            } else {
                Spacer(); Text("No supply group selected.").foregroundStyle(.secondary); Spacer()
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .onAppear { if !store.catalog.groups.indices.contains(groupIndex) { groupIndex = 0 } }
        .alert("Restore the factory supply catalog?", isPresented: $confirmRestore) {
            Button("Restore defaults", role: .destructive) {
                store.restoreDefaults(); groupIndex = 0; selectedSupply = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces every group, category, supply and part number with the built-in Brady defaults. Your customisations will be lost.")
        }
    }

    // MARK: Group bar

    private var groupBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Supply group").font(.system(size: 12, weight: .semibold))
                Picker("", selection: $groupIndex) {
                    ForEach(Array(store.catalog.groups.enumerated()), id: \.offset) { i, g in
                        Text(g.name.isEmpty ? "Untitled" : g.name).tag(i)
                    }
                }.labelsHidden().frame(width: 220)
                Button { addGroup() } label: { Image(systemName: "plus") }
                    .help("Add a supply group")
                Button { deleteGroup() } label: { Image(systemName: "trash") }
                    .help("Delete this supply group")
                    .disabled(store.catalog.groups.count <= 1)
                Spacer()
                Button("Restore defaults…") { confirmRestore = true }
            }
            if store.catalog.groups.indices.contains(groupIndex) {
                HStack(spacing: 6) {
                    Text("Group name").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("Group name", text: groupBinding(group.id).name).frame(width: 200)
                    Text("Printer models").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 8)
                    TextField("e.g. M610, M611", text: modelsBinding(group.id)).frame(width: 200)
                    Text("comma-separated").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
        }
    }

    // Id-keyed bindings — safe against SwiftUI committing an in-flight TextField
    // edit through a stale INDEX after the array was mutated (add/delete/move/drag),
    // which crashes with "Index out of range". Each get/set looks the element up by
    // id and no-ops if it's gone.
    private func groupBinding(_ gid: UUID) -> Binding<SupplyGroup> {
        Binding(get: { store.catalog.groups.first { $0.id == gid }
                        ?? SupplyGroup(name: "", printerModels: [], categories: []) },
                set: { v in if let i = store.catalog.groups.firstIndex(where: { $0.id == gid }) { store.catalog.groups[i] = v } })
    }
    private func modelsBinding(_ gid: UUID) -> Binding<String> {
        Binding(get: { (store.catalog.groups.first { $0.id == gid }?.printerModels ?? []).joined(separator: ", ") },
                set: { v in if let i = store.catalog.groups.firstIndex(where: { $0.id == gid }) {
                    store.catalog.groups[i].printerModels = v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } })
    }
    private func categoryNameBinding(_ cid: UUID) -> Binding<String> {
        Binding(get: { for g in store.catalog.groups { for c in g.categories where c.id == cid { return c.name } }; return "" },
                set: { v in for gi in store.catalog.groups.indices { for ci in store.catalog.groups[gi].categories.indices
                    where store.catalog.groups[gi].categories[ci].id == cid { store.catalog.groups[gi].categories[ci].name = v; return } } })
    }
    private func supplyValue(_ sid: UUID) -> Supply? {
        for g in store.catalog.groups { for c in g.categories { if let s = c.supplies.first(where: { $0.id == sid }) { return s } } }
        return nil
    }
    private func mutateSupply(_ sid: UUID, _ f: (inout Supply) -> Void) {
        for gi in store.catalog.groups.indices {
            for ci in store.catalog.groups[gi].categories.indices {
                if let si = store.catalog.groups[gi].categories[ci].supplies.firstIndex(where: { $0.id == sid }) {
                    f(&store.catalog.groups[gi].categories[ci].supplies[si]); return
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

    // MARK: Categories + supplies

    private var categoriesPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(group.categories.enumerated()), id: \.element.id) { ci, cat in
                    categorySection(ci: ci, cat: cat)
                }
                Button { addCategory() } label: { Label("Add category", systemImage: "plus") }
                    .buttonStyle(.borderless).padding(.top, 4)
            }
            .padding(12)
        }
    }

    private func categorySection(ci: Int, cat: SupplyCategory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                TextField("Category name", text: categoryNameBinding(cat.id))
                    .font(.system(size: 12, weight: .semibold)).textFieldStyle(.plain)
                Spacer()
                Button { addSupply(ci: ci) } label: { Image(systemName: "plus.circle") }
                    .buttonStyle(.borderless).help("Add a supply to this category")
                Button { deleteCategory(ci: ci) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).help("Delete this category").disabled(group.categories.count <= 1)
            }
            ForEach(Array(cat.supplies.enumerated()), id: \.element.id) { si, s in
                supplyRow(ci: ci, si: si, s: s)
            }
            if cat.supplies.isEmpty {
                Text("Drag supplies here, or add one.").font(.system(size: 11))
                    .foregroundStyle(.tertiary).padding(.vertical, 6).padding(.leading, 22)
            }
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
            Button("Delete supply", role: .destructive) { deleteSupply(s.id) }
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
                Button(role: .destructive) { deleteSupply(sid) } label: { Label("Delete", systemImage: "trash") }
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
                GridRow {
                    Text(cont ? "Width / default len" : "Label W × H")
                    HStack(spacing: 6) {
                        numField(sB.widthInches); Text("×").foregroundStyle(.secondary); numField(sB.heightInches)
                        Text("in").foregroundStyle(.secondary)
                    }
                }
                GridRow {
                    Text(cont ? "Printable width" : "Printable W × H")
                    HStack(spacing: 6) {
                        numField(sB.printableWidthInches); Text("×").foregroundStyle(.secondary); numField(sB.printableHeightInches)
                        Text("in").foregroundStyle(.secondary)
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
                    TextField("Material", text: pB.materialLabel).frame(width: 90)
                    Text("len"); numFieldOptD(pB.rollLengthFeet, width: 50); Text("ft").foregroundStyle(.secondary)
                } else {
                    Text("qty"); numFieldOptI(pB.quantityPerRoll, width: 56); Text("/roll").foregroundStyle(.secondary)
                    Toggle("Rotate 90°", isOn: pB.rotate90).toggleStyle(.checkbox).font(.system(size: 11))
                }
                Spacer()
                Button { deletePart(sid, pid) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
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
        TextField("", value: b, format: .number).frame(width: 54).multilineTextAlignment(.trailing)
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
        store.catalog.groups.indices.contains(groupIndex) ? store.catalog.groups[groupIndex]
            : SupplyGroup(name: "", printerModels: [], categories: [])
    }

    private func addGroup() {
        store.catalog.groups.append(SupplyGroup(name: "New group", printerModels: [],
            categories: [SupplyCategory(name: "Category", supplies: [])]))
        groupIndex = store.catalog.groups.count - 1
        selectedSupply = nil
    }
    private func deleteGroup() {
        guard store.catalog.groups.count > 1, store.catalog.groups.indices.contains(groupIndex) else { return }
        store.catalog.groups.remove(at: groupIndex)
        groupIndex = min(groupIndex, store.catalog.groups.count - 1)
        selectedSupply = nil
    }
    private func addCategory() {
        guard store.catalog.groups.indices.contains(groupIndex) else { return }
        store.catalog.groups[groupIndex].categories.append(SupplyCategory(name: "New category", supplies: []))
    }
    private func deleteCategory(ci: Int) {
        guard store.catalog.groups.indices.contains(groupIndex),
              store.catalog.groups[groupIndex].categories.count > 1,
              store.catalog.groups[groupIndex].categories.indices.contains(ci) else { return }
        store.catalog.groups[groupIndex].categories.remove(at: ci)
    }
    private func addSupply(ci: Int) {
        guard store.catalog.groups.indices.contains(groupIndex),
              store.catalog.groups[groupIndex].categories.indices.contains(ci) else { return }
        let s = Supply(name: "New supply", kind: .dieCut, widthInches: 1, heightInches: 1,
                       printableWidthInches: 1, printableHeightInches: 1,
                       parts: [SupplyPartNumber(partNumber: "")])
        store.catalog.groups[groupIndex].categories[ci].supplies.append(s)
        selectedSupply = s.id
    }
    private func deleteSupply(_ sid: UUID) {
        for gi in store.catalog.groups.indices {
            for ci in store.catalog.groups[gi].categories.indices {
                if let si = store.catalog.groups[gi].categories[ci].supplies.firstIndex(where: { $0.id == sid }) {
                    store.catalog.groups[gi].categories[ci].supplies.remove(at: si)
                    if selectedSupply == sid { selectedSupply = nil }
                    return
                }
            }
        }
    }
    private func moveSupply(_ id: UUID, toCategory cid: UUID) {
        guard store.catalog.groups.indices.contains(groupIndex) else { return }
        var cats = store.catalog.groups[groupIndex].categories
        var moved: Supply?
        for ci in cats.indices {
            if let si = cats[ci].supplies.firstIndex(where: { $0.id == id }) { moved = cats[ci].supplies.remove(at: si); break }
        }
        guard let supply = moved, let dci = cats.firstIndex(where: { $0.id == cid }) else { return }
        cats[dci].supplies.append(supply)
        store.catalog.groups[groupIndex].categories = cats
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
