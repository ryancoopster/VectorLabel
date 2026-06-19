import SwiftUI
import AppKit
import VectorLabelCore
import PrinterM610
import VectorLabelEngineKit

// Design tokens (Color.vl*) live in Theme.swift, shared with the menu bar.

// MARK: – Shared row/section components

private struct PrefSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.vlDim)
                .padding(.horizontal, 16)
                .padding(.top, 18)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Color.vlSurface2)
            .cornerRadius(8)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.vlBorder, lineWidth: 1))
            .padding(.horizontal, 16)
        }
    }
}

private struct PrefRow<Content: View>: View {
    let label: String
    var caption: String? = nil
    @ViewBuilder let control: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 13))
                        .foregroundColor(.vlLabel)
                    if let cap = caption {
                        Text(cap)
                            .font(.system(size: 11))
                            .foregroundColor(.vlSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                control()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }
}

private struct PrefDivider: View {
    var body: some View {
        Divider().background(Color.vlBorder).padding(.leading, 16)
    }
}

// MARK: – Main view

struct PreferencesView: View {
    @ObservedObject var settings        = AppSettings.shared
    @ObservedObject var recentPrints    = RecentPrintsStore.shared
    @ObservedObject var printerManager  = PrinterManager.shared

    @State private var selectedTab = 0
    @State private var showResetConfirm       = false
    @State private var showClearRecentConfirm = false
    @State private var newPrinterHost = ""

    private let tabs = ["Export", "Printing", "Templates", "Recent", "Printers", "Advanced"]
    private let icons = ["arrow.down.doc", "printer", "doc.richtext", "clock", "cable.connector", "gearshape.2"]

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            HStack(spacing: 0) {
                ForEach(Array(tabs.enumerated()), id: \.offset) { i, tab in
                    Button {
                        selectedTab = i
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icons[i])
                                .font(.system(size: 16))
                            Text(tab)
                                .font(.system(size: 10))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundColor(selectedTab == i ? .vlAccent : .vlSecondary)
                        .background(selectedTab == i ? Color.vlAccent.opacity(0.12) : Color.clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color.vlSurface)
            .overlay(Divider().background(Color.vlBorder), alignment: .bottom)

            // Content
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    switch selectedTab {
                    case 0: exportTab
                    case 1: printingTab
                    case 2: templatesTab
                    case 3: recentTab
                    case 4: printersTab
                    default: advancedTab
                    }
                }
                .padding(.bottom, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.vlBackground)
        }
        .frame(width: 600, height: 480)
        .background(Color.vlBackground)
        // Respect the chosen appearance (was hardcoded .preferredColorScheme(.dark),
        // which kept Preferences dark in light mode). Tie identity to the appearance
        // so the whole window re-themes on a flip (the vl* tokens are global reads).
        .id("\(settings.appearance)-\(settings.systemAppearanceTick)")
    }

    // MARK: – Export

    private var exportTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Watch Folder") {
                PrefRow(
                    label: "Folder",
                    caption: "VectorLabel watches [folder]/Exports/ and all project subfolders for new CSV exports."
                ) {
                    HStack(spacing: 8) {
                        Text(abbreviatedPath(settings.watchFolderPath))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.vlSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .trailing)
                        Button("Browse…") { browseWatchFolder() }
                            .buttonStyle(VLButtonStyle())
                    }
                }
            }

            PrefSection(title: "Behaviour") {
                PrefRow(label: "Auto-open print window when export is detected") {
                    Toggle("", isOn: $settings.autoOpenPrintWindow)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }

            PrefSection(title: "History") {
                PrefRow(
                    label: "Exports to keep per project",
                    caption: "Oldest exports are pruned using the date code in the filename, not filesystem metadata — safe with cloud sync."
                ) {
                    Stepper("\(settings.maxExportsPerProject)", value: $settings.maxExportsPerProject, in: 1...100)
                        .foregroundColor(.vlLabel)
                }
            }
        }
    }

    // MARK: – Printing

    private var printingTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Default Print Range") {
                PrefRow(label: "When the print window opens, default to") {
                    Picker("", selection: $settings.defaultPrintRange) {
                        Text("All").tag("all")
                        Text("Selected").tag("selected")
                        Text("Range").tag("range")
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                    .labelsHidden()
                }
            }

            PrefSection(title: "Hardware") {
                PrefRow(
                    label: "Inter-label delay & print mode",
                    caption: "These are now per-printer-model. Set the inter-label delay and full-job / single-label mode under Printers ▸ Printer Models…"
                ) {
                    Button("Printer Models…") { PrinterModelEditorWindow.shared.show() }
                }
            }
        }
    }

    // MARK: – Templates

    private var templatesTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Templates Folder") {
                PrefRow(
                    label: "Folder",
                    caption: "Template files (.vltmp) saved from the designer are stored here."
                ) {
                    HStack(spacing: 8) {
                        Text(abbreviatedPath(settings.templatesFolderPath))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.vlSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 200, alignment: .trailing)
                        Button("Browse…") { browseTemplatesFolder() }
                            .buttonStyle(VLButtonStyle())
                    }
                }
            }
        }
    }

    // MARK: – Recent prints

    private var recentTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "History") {
                PrefRow(label: "Recent prints",
                        caption: "The full print history is kept and shown — scrollable — in the menu bar, with buttons to jump to the top/bottom and clear it.") {
                    EmptyView()
                }
            }

            PrefSection(title: "Danger Zone") {
                PrefRow(label: "Clear all \(recentPrints.prints.count) recent print record\(recentPrints.prints.count == 1 ? "" : "s")") {
                    Button("Clear History") { showClearRecentConfirm = true }
                        .buttonStyle(VLDestructiveButtonStyle())
                        .confirmationDialog(
                            "Clear all recent print records?",
                            isPresented: $showClearRecentConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Clear History", role: .destructive) { recentPrints.clear() }
                        }
                }
            }
        }
    }

    // MARK: – Printers

    private func addNetworkPrinter() {
        let host = newPrinterHost.trimmingCharacters(in: .whitespaces)
        guard !host.isEmpty else { return }
        PrinterManager.shared.addNetworkPrinter(name: "Brady M611 (\(host))", host: host)
        newPrinterHost = ""
    }

    /// Caption for a printer row, including the detected cassette if known.
    private func printerCaption(_ printer: PrinterDevice, _ cassette: CassetteStatus?) -> String {
        var s = "Serial: \(printer.serial)  ·  \(printer.status.displayName)"
        if let c = cassette, !c.partNumber.isEmpty {
            let dims = "\(c.labelWidthMils)×\(c.labelHeightMils) mil"
            s += "  ·  Loaded: \(c.partNumber) (\(dims))"
            if let rib = c.ribbonPartNumber, !rib.isEmpty { s += "  ·  Ribbon: \(rib)" }
        }
        return s
    }

    private static let pxFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal; f.maximumFractionDigits = 0; f.allowsFloats = false
        return f
    }()

    /// Per-printer alignment controls: print a calibration grid, then nudge the
    /// horizontal/vertical offset (in printer pixels) until the grid lands square
    /// on the label. Offsets are keyed by serial so they follow the printer.
    @ViewBuilder
    private func calibrationControls(for printer: PrinterDevice) -> some View {
        let dpi = printerManager.calibrationSize(for: printer.id).dpi
        let dxB = Binding<Double>(
            get: { settings.calibrationOffset(forSerial: printer.serial).dx },
            set: { settings.setCalibrationOffset(forSerial: printer.serial, dx: $0,
                     dy: settings.calibrationOffset(forSerial: printer.serial).dy) })
        let dyB = Binding<Double>(
            get: { settings.calibrationOffset(forSerial: printer.serial).dy },
            set: { settings.setCalibrationOffset(forSerial: printer.serial,
                     dx: settings.calibrationOffset(forSerial: printer.serial).dx, dy: $0) })
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button("Print calibration grid") {
                    PrinterManager.shared.printCalibrationGrid(for: printer.id)
                }
                .buttonStyle(VLButtonStyle())
                .disabled(printer.status != .ready)
                Text("\(dpi) px = 1 inch  (\(dpi) DPI)")
                    .foregroundColor(.vlDim).font(.system(size: 11))
            }
            HStack(spacing: 16) {
                offsetField("Horizontal", dxB)
                offsetField("Vertical", dyB)
                Button("Reset") {
                    settings.setCalibrationOffset(forSerial: printer.serial, dx: 0, dy: 0)
                }
                .buttonStyle(VLButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private func offsetField(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(.vlSecondary).font(.system(size: 12))
            TextField("0", value: binding, formatter: Self.pxFormatter)
                .frame(width: 52).textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Stepper("", value: binding, step: 1).labelsHidden()
            Text("px").foregroundColor(.vlDim).font(.system(size: 11))
        }
    }

    private var printersTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Connected Printers") {
                // Always-visible scan control: choose USB or a network subnet scan.
                PrefRow(label: printerManager.printers.isEmpty ? "No printers detected"
                            : "\(printerManager.printers.count) printer\(printerManager.printers.count == 1 ? "" : "s") connected",
                        caption: printerManager.networkScanMessage) {
                    Menu("Scan") {
                        Button("Scan USB") { PrinterManager.shared.scanNow() }
                        Button(printerManager.isScanningNetwork ? "Scanning network…" : "Scan network (subnet)") {
                            PrinterManager.shared.scanNetwork()
                        }
                        .disabled(printerManager.isScanningNetwork)
                    }
                    .fixedSize()
                }
                // Manually add a network printer by IP / hostname.
                PrefRow(label: "Add network printer", caption: "Enter the printer's IP address (port 9100/9102)") {
                    HStack(spacing: 8) {
                        TextField("192.168.1.50", text: $newPrinterHost)
                            .textFieldStyle(.roundedBorder).frame(width: 150)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit { addNetworkPrinter() }
                        Button("Add") { addNetworkPrinter() }
                            .buttonStyle(VLButtonStyle())
                            .disabled(newPrinterHost.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                if !printerManager.printers.isEmpty {
                    PrefDivider()
                    ForEach(printerManager.printers) { printer in
                        VStack(alignment: .leading, spacing: 8) {
                            PrefRow(label: printer.name,
                                    caption: printerCaption(printer, printerManager.cassettes[printer.id])) {
                                HStack(spacing: 8) {
                                    Button("Detect cassette") {
                                        PrinterManager.shared.refreshCassette(for: printer.id, force: true)
                                    }
                                    .buttonStyle(VLButtonStyle())
                                    .disabled(printer.status != .ready)
                                    if printer.id.hasPrefix("net:"), let host = printer.host {
                                        Button("Remove") { PrinterManager.shared.removeNetworkPrinter(host: host) }
                                            .buttonStyle(VLButtonStyle())
                                    }
                                    Circle()
                                        .fill(printer.status == .ready ? Color.vlGreen : printer.status == .busy ? Color.yellow : Color.vlDim)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            calibrationControls(for: printer)
                        }
                        if printer.id != printerManager.printers.last?.id {
                            PrefDivider()
                        }
                    }
                }
            }
            PrefSection(title: "Printer Models") {
                PrefRow(
                    label: "Printer models & USB IDs",
                    caption: "Manage the printer models (and their USB vendor/product IDs) that the supply catalog's groups are assigned to."
                ) {
                    Button("Printer Models…") { PrinterModelEditorWindow.shared.show() }
                        .buttonStyle(VLButtonStyle())
                }
            }
            PrefSection(title: "Label Supplies") {
                PrefRow(
                    label: "Edit supply catalog",
                    caption: "Customise the label supplies (categories, sizes, part numbers, quantities/roll lengths, 90° rotation and buy links) for each printer model."
                ) {
                    Button("Edit Supplies…") { SupplyCatalogEditorWindow.shared.show() }
                        .buttonStyle(VLButtonStyle())
                }
            }
        }
    }

    // MARK: – Advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 0) {
PrefSection(title: "App Behaviour") {
                PrefRow(
                    label: "Appearance",
                    caption: "Switch the menu, Preferences, print, and designer windows between dark, light, or following the system."
                ) {
                    AppearanceSlider().frame(width: 230)
                }
            }

            PrefSection(title: "Danger Zone") {
                PrefRow(label: "Reset all settings to factory defaults") {
                    Button("Reset Defaults") { showResetConfirm = true }
                        .buttonStyle(VLDestructiveButtonStyle())
                        .confirmationDialog(
                            "Reset all VectorLabel settings to defaults?",
                            isPresented: $showResetConfirm,
                            titleVisibility: .visible
                        ) {
                            Button("Reset Settings", role: .destructive) {
                                settings.resetToDefaults()
                            }
                        }
                }
            }
        }
    }

    // MARK: – Helpers

    private func abbreviatedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

private func browseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select Watch Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.watchFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.watchFolderPath = url.path
        }
    }

    private func browseTemplatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.canCreateDirectories = true; panel.prompt = "Select Templates Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.templatesFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.templatesFolderPath = url.path
        }
    }
}

// MARK: – Button styles

struct VLButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.vlLabel)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.vlHoverStrong : Color.vlHover)
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.vlBorder, lineWidth: 1))
            .cornerRadius(5)
    }
}

struct VLDestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .foregroundColor(.vlRed)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(configuration.isPressed ? Color.vlRed.opacity(0.15) : Color.vlRed.opacity(0.08))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.vlRed.opacity(0.3), lineWidth: 1))
            .cornerRadius(5)
    }
}

// PrinterManager.scanNow() is defined in PrinterManager.swift
