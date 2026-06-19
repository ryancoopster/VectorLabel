import SwiftUI
import AppKit
import VectorLabelCore
import VectorLabelUI

// MARK: – Printer-models editor (Engine ▸ Preferences ▸ Printers ▸ Printer Models…)
//
// Edits the PrinterModelStore: the printer models + their USB IDs that the supply
// catalog's groups link to. Works on a DRAFT — Apply commits, Cancel reverts.

struct PrinterModelEditorView: View {
    @ObservedObject private var store = PrinterModelStore.shared
    @State private var draft: PrinterModelList
    @State private var pendingDelete: PendingDelete?
    let onClose: () -> Void

    /// A model deletion awaiting confirmation.
    struct PendingDelete: Identifiable {
        let modelID: UUID
        let name: String
        var id: UUID { modelID }
    }

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        _draft = State(initialValue: PrinterModelStore.snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Printer Models").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button { addModel() } label: { Label("Add model", systemImage: "plus") }
            }.padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(draft.models) { m in modelCard(m.id) }
                    if draft.models.isEmpty {
                        Text("No printer models. Add one to make it available in the supply catalog.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 8)
                    }
                }.padding(12)
            }
            Divider()
            HStack(spacing: 8) {
                Button("Restore defaults") { draft = .makeDefault() }
                Spacer()
                Button("Cancel") { onClose() }                                   // revert: discard the draft
                Button("Apply") { store.replace(with: draft) }
                Button("Apply & Close") { store.replace(with: draft); onClose() }
                    .keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth: 540, minHeight: 440)
        .alert(item: $pendingDelete) { d in
            Alert(title: Text("Delete the “\(d.name)” printer model?"),
                  message: Text("This can’t be undone. The supply catalog will no longer be able to link supplies to it."),
                  primaryButton: .destructive(Text("Delete")) {
                      draft.models.removeAll { $0.id == d.modelID }
                  },
                  secondaryButton: .cancel())
        }
    }

    private func modelCard(_ mid: UUID) -> some View {
        let m = draft.models.first { $0.id == mid }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("e.g. M611", text: modelName(mid)).frame(width: 140)
                Spacer()
                Button(role: .destructive) {
                    let nm = (m?.name).map { $0.isEmpty ? "this model" : $0 } ?? "this model"
                    pendingDelete = PendingDelete(modelID: mid, name: nm)
                } label: { Label("Delete", systemImage: "trash") }
                    .buttonStyle(.borderless)
            }
            ForEach(m?.usbIDs ?? []) { u in
                HStack(spacing: 6) {
                    Text("VID 0x").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0E2E", text: usbField(mid, u.id, \.vendorID)).frame(width: 64).font(.system(.body, design: .monospaced))
                    Text("PID 0x").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("010C", text: usbField(mid, u.id, \.productID)).frame(width: 64).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { removeUSB(mid, u.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { addUSB(mid) } label: { Label("Add USB ID", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(.system(size: 11))

            Divider().padding(.vertical, 2)

            // Per-model print behavior (built into the driver).
            Toggle(isOn: singleLabelBinding(mid)) {
                Text("Send one label at a time").font(.system(size: 12))
            }
            Text("On: each label is sent as its own print — the menu shows per-label progress and the inter-label delay applies. Off: the whole job is sent at once (the menu shows live progress only if the printer reports it, otherwise just “Printing”).")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text("Inter-label delay").font(.system(size: 11)).foregroundStyle(.secondary)
                Stepper("", value: delayBinding(mid), in: 0...2000, step: 5).labelsHidden()
                Text("\(m?.interLabelDelayMs ?? 0) ms")
                    .font(.system(.body, design: .monospaced)).frame(width: 60, alignment: .trailing)
            }
            .disabled(!(m?.singleLabelPrinting ?? false))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.gray.opacity(0.06)))
    }

    // Id-keyed bindings into the draft (crash-safe against edit-after-delete).
    private func modelName(_ mid: UUID) -> Binding<String> {
        Binding(get: { draft.models.first { $0.id == mid }?.name ?? "" },
                set: { v in if let i = draft.models.firstIndex(where: { $0.id == mid }) { draft.models[i].name = v } })
    }
    private func usbField(_ mid: UUID, _ uid: UUID, _ kp: WritableKeyPath<PrinterUSBID, String>) -> Binding<String> {
        Binding(
            get: { draft.models.first { $0.id == mid }?.usbIDs.first { $0.id == uid }?[keyPath: kp] ?? "" },
            set: { v in
                guard let mi = draft.models.firstIndex(where: { $0.id == mid }),
                      let ui = draft.models[mi].usbIDs.firstIndex(where: { $0.id == uid }) else { return }
                draft.models[mi].usbIDs[ui][keyPath: kp] = v.uppercased()
            })
    }
    private func singleLabelBinding(_ mid: UUID) -> Binding<Bool> {
        Binding(get: { draft.models.first { $0.id == mid }?.singleLabelPrinting ?? false },
                set: { v in if let i = draft.models.firstIndex(where: { $0.id == mid }) { draft.models[i].singleLabelPrinting = v } })
    }
    private func delayBinding(_ mid: UUID) -> Binding<Int> {
        Binding(get: { draft.models.first { $0.id == mid }?.interLabelDelayMs ?? 0 },
                set: { v in if let i = draft.models.firstIndex(where: { $0.id == mid }) { draft.models[i].interLabelDelayMs = max(0, v) } })
    }
    private func addModel() {
        draft.models.append(PrinterModel(name: "New model", usbIDs: [PrinterUSBID(vendorID: "0E2E", productID: "")]))
    }
    private func addUSB(_ mid: UUID) {
        guard let i = draft.models.firstIndex(where: { $0.id == mid }) else { return }
        draft.models[i].usbIDs.append(PrinterUSBID(vendorID: "0E2E", productID: ""))
    }
    private func removeUSB(_ mid: UUID, _ uid: UUID) {
        guard let i = draft.models.firstIndex(where: { $0.id == mid }) else { return }
        draft.models[i].usbIDs.removeAll { $0.id == uid }
    }
}

// MARK: – Window

@MainActor
final class PrinterModelEditorWindow {
    static let shared = PrinterModelEditorWindow()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show() {
        if let w = window { NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil); return }
        let win = NSWindow(contentViewController: NSHostingController(rootView:
            PrinterModelEditorView(onClose: { [weak self] in self?.close() })))
        win.title = "Printer Models"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        win.applyVLSizing(autosaveName: "VLPrinterModelsWindow", defaultContentSize: NSSize(width: 560, height: 460))
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        window = win
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: win, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self = self else { return }
                if let t = self.closeObserver { NotificationCenter.default.removeObserver(t) }
                self.closeObserver = nil
                self.window = nil
            }
        }
    }

    func close() { window?.close() }
}
