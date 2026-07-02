import SwiftUI
import AppKit
import VectorLabelCore
import VectorLabelUI

// MARK: – Per-printer settings editor (Engine ▸ Preferences ▸ Printers ▸ Per-Printer Settings…)
//
// Edits the PrinterModelStore: each printer (name + USB IDs), the connection methods
// to use, and the print behavior (full-job vs single-label). The
// supply catalog's groups link to these printers. Works on a DRAFT — Apply / Cancel.

struct PrinterModelEditorView: View {
    @ObservedObject private var store = PrinterModelStore.shared
    @State private var draft: PrinterModelList
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
        _draft = State(initialValue: PrinterModelStore.snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Per-Printer Settings").font(.system(size: 14, weight: .semibold))
                Text("The printers VectorLabel has drivers for. Edit each one's USB IDs, connection methods, and print mode.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(draft.models) { m in modelCard(m.id) }
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
    }

    private func modelCard(_ mid: UUID) -> some View {
        let m = draft.models.first { $0.id == mid }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Printer").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("e.g. M611", text: modelName(mid)).frame(width: 140)
                Spacer()
            }
            ForEach(m?.usbIDs ?? []) { u in
                HStack(spacing: 6) {
                    Text("VID 0x").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0E2E", text: usbField(mid, u.id, \.vendorID)).frame(width: 64).font(.system(.body, design: .monospaced))
                    Text("PID 0x").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0013", text: usbField(mid, u.id, \.productID)).frame(width: 64).font(.system(.body, design: .monospaced))
                    Spacer()
                    Button { removeUSB(mid, u.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless)
                }
            }
            Button { addUSB(mid) } label: { Label("Add USB ID", systemImage: "plus.circle") }
                .buttonStyle(.borderless).font(.system(size: 11))

            Divider().padding(.vertical, 2)

            connectionsRow(mid)

            Divider().padding(.vertical, 2)

            // Per-model send mode (the driver decides how it sends + what progress it
            // reports). Greyed out for drivers that report live progress on their own.
            HStack(spacing: 8) {
                Text("Send mode").font(.system(size: 12))
                Picker("", selection: singleLabelBinding(mid)) {
                    Text("One at a time").tag(true)
                    Text("Full job").tag(false)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(sendModeFixed(mid))
            }
            Text(sendModeFixed(mid)
                 ? "This printer reports live print progress on its own, so it always streams as one job."
                 : "One at a time: each label is its own print job — per-label progress, and you can cancel mid-run (the in-flight labels finish, the rest are dropped). Full job: the whole job is sent at once — fastest, but the M611 can’t be cancelled once it starts and shows only “Printing”. Both run at full speed.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    // Connection-method checkboxes (all on by default). The driver decides which
    // actually take effect (PrinterCapabilities.supportedTransports); enabling one the
    // driver doesn't support is a harmless no-op.
    private func connectionsRow(_ mid: UUID) -> some View {
        let name = draft.models.first { $0.id == mid }?.name ?? ""
        let supported = supportedTransports(forModelNamed: name)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 14) {
                Text("Connections").font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(supported, id: \.self) { t in
                    Toggle(t.displayName, isOn: transportBinding(mid, t)).toggleStyle(.checkbox)
                }
            }
            Text("Connection methods this printer's driver supports.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    /// Transports the registered driver for `name` supports, in display order. Falls back
    /// to all methods for a custom printer with no matching driver (so it isn't blocked).
    private func supportedTransports(forModelNamed name: String) -> [PrinterTransport] {
        let set = PrinterModuleRegistry.shared.module(forModel: name)?.capabilities.supportedTransports
            ?? Set(PrinterTransport.allCases)
        return PrinterTransport.allCases.filter { set.contains($0) }
    }
    private func transportBinding(_ mid: UUID, _ t: PrinterTransport) -> Binding<Bool> {
        Binding(
            get: { draft.models.first { $0.id == mid }?.enabledTransports.contains(t) ?? false },
            set: { on in
                guard let i = draft.models.firstIndex(where: { $0.id == mid }) else { return }
                if on { draft.models[i].enabledTransports.insert(t) }
                else  { draft.models[i].enabledTransports.remove(t) }
            })
    }
    private func singleLabelBinding(_ mid: UUID) -> Binding<Bool> {
        Binding(get: { draft.models.first { $0.id == mid }?.singleLabelPrinting ?? false },
                set: { v in if let i = draft.models.firstIndex(where: { $0.id == mid }) { draft.models[i].singleLabelPrinting = v } })
    }
    /// True when the model's driver reports live progress on its own (`sendMode == .fixed`),
    /// so the one-at-a-time vs full-job choice doesn't apply — the UI greys it out.
    private func sendModeFixed(_ mid: UUID) -> Bool {
        let name = draft.models.first { $0.id == mid }?.name ?? ""
        if case .fixed = PrinterModuleRegistry.shared.module(forModel: name)?.capabilities.sendMode { return true }
        return false
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
        win.title = "Per-Printer Settings"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.isReleasedWhenClosed = false
        win.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        // Default tall enough to show two printer cards without scrolling; capped to the
        // screen and persisted on resize. Autosave key bumped (…Window2) so a stale saved
        // frame from the earlier (shorter) default doesn't override the new height.
        win.applyVLSizing(autosaveName: "VLPrinterModelsWindow2", defaultContentSize: NSSize(width: 560, height: 700))
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
