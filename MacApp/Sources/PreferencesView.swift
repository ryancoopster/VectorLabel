import SwiftUI
import AppKit

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
        .preferredColorScheme(.dark)
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
                    label: "Inter-label delay",
                    caption: "Pause between consecutive label jobs sent to the printer. Increase this if labels are dropped or misprinted."
                ) {
                    HStack(spacing: 6) {
                        Stepper("", value: $settings.interLabelDelayMs, in: 0...2000, step: 10)
                            .labelsHidden()
                        Text("\(settings.interLabelDelayMs) ms")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.vlLabel)
                            .frame(width: 54, alignment: .trailing)
                    }
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
                    caption: "Template files (.vlt.json) saved from the designer are stored here."
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
                PrefRow(label: "Recent print jobs to show in menu bar",
                        caption: "Number of recent prints listed in the menu bar dropdown.") {
                    Stepper(value: $settings.recentPrintsCount, in: 1...25) {
                        Text("\(settings.recentPrintsCount)")
                            .font(.system(size: 13, weight: .medium))
                            .frame(minWidth: 24, alignment: .trailing)
                            .monospacedDigit()
                    }
                    .fixedSize()
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

    /// Caption for a printer row, including the detected cassette if known.
    private func printerCaption(_ printer: PrinterDevice, _ cassette: BradyUSB.SmartCellInfo?) -> String {
        var s = "Serial: \(printer.serial)  ·  \(printer.status.displayName)"
        if let c = cassette, !c.partNumber.isEmpty {
            let dims = "\(c.labelWidthMils)×\(c.labelHeightMils) mil"
            s += "  ·  Loaded: \(c.partNumber) (\(dims), \(c.supplyRemainingPct)% left)"
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
            PrefRow(label: printer.name,
                    caption: "\(dpi) px = 1 inch  (\(dpi) DPI).  Positive Horizontal shifts content along the label; positive Vertical shifts it down. Saved for serial \(printer.serial).") {
                Button("Print calibration grid") {
                    PrinterManager.shared.printCalibrationGrid(for: printer.id)
                }
                .buttonStyle(VLButtonStyle())
                .disabled(printer.status != .ready)
            }
            HStack(spacing: 16) {
                offsetField("Horizontal", dxB)
                offsetField("Vertical", dyB)
                Button("Reset") {
                    settings.setCalibrationOffset(forSerial: printer.serial, dx: 0, dy: 0)
                }
                .buttonStyle(VLButtonStyle())
                Button("SmartCell dump") {
                    PrinterManager.shared.dumpSmartCell(for: printer.id)
                }
                .buttonStyle(VLButtonStyle())
                .disabled(printer.status != .ready)
            }
            .padding(.leading, 2)

            if !printerManager.lastSmartCellDump.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("SmartCell diagnostics")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.vlSecondary)
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(printerManager.lastSmartCellDump, forType: .string)
                        }
                        .buttonStyle(VLButtonStyle())
                    }
                    ScrollView {
                        Text(printerManager.lastSmartCellDump)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.vlSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 150)
                    .padding(6)
                    .background(Color.black.opacity(0.25))
                    .cornerRadius(6)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private func offsetField(_ label: String, _ binding: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundColor(.vlSecondary).font(.system(size: 12))
            TextField("0", value: binding, formatter: Self.pxFormatter)
                .frame(width: 52).textFieldStyle(.roundedBorder).colorScheme(.dark)
                .font(.system(size: 12, design: .monospaced))
            Stepper("", value: binding, step: 1).labelsHidden()
            Text("px").foregroundColor(.vlDim).font(.system(size: 11))
        }
    }

    private var printersTab: some View {
        VStack(alignment: .leading, spacing: 0) {
            PrefSection(title: "Connected Printers") {
                if printerManager.printers.isEmpty {
                    PrefRow(label: "No Brady printers detected") {
                        Button("Scan Now") { Task { @MainActor in PrinterManager.shared.scanNow() } }
                            .buttonStyle(VLButtonStyle())
                    }
                } else {
                    ForEach(printerManager.printers) { printer in
                        PrefRow(label: printer.name,
                                caption: printerCaption(printer, printerManager.cassettes[printer.id])) {
                            HStack(spacing: 8) {
                                Button("Detect cassette") {
                                    PrinterManager.shared.refreshCassette(for: printer.id, force: true)
                                }
                                .buttonStyle(VLButtonStyle())
                                .disabled(printer.status != .ready)
                                Circle()
                                    .fill(printer.status == .ready ? Color.vlGreen : printer.status == .busy ? Color.yellow : Color.vlDim)
                                    .frame(width: 8, height: 8)
                            }
                        }
                        if printer.id != printerManager.printers.last?.id {
                            PrefDivider()
                        }
                    }
                }
            }

            if !printerManager.printers.isEmpty {
                PrefSection(title: "Printer Calibration") {
                    ForEach(Array(printerManager.printers.enumerated()), id: \.element.id) { idx, printer in
                        calibrationControls(for: printer)
                        if idx != printerManager.printers.count - 1 { PrefDivider() }
                    }
                }
            }

            PrefSection(title: "Brady M611 PID Override") {
                PrefRow(
                    label: "Product ID (hex)",
                    caption: "The M611 PID hasn't been confirmed. If your M611 isn't detected, connect it, run  system_profiler SPUSBDataType  in Terminal, find the Brady entry, and enter the idProduct value here."
                ) {
                    HStack(spacing: 2) {
                        Text("0x")
                            .foregroundColor(.vlSecondary)
                            .font(.system(size: 12, design: .monospaced))
                        TextField("010C", text: $settings.m611ProductIDOverride)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52)
                            .textFieldStyle(.roundedBorder)
                            .colorScheme(.dark)
                    }
                }
            }
        }
    }

    // MARK: – Advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 0) {
PrefSection(title: "App Behaviour") {
                PrefRow(
                    label: "Show VectorLabel in Dock",
                    caption: "By default VectorLabel runs as a menu-bar-only app. Enable this to also show an icon in the Dock."
                ) {
                    Toggle("", isOn: $settings.showInDock)
                        .toggleStyle(.switch)
                        .labelsHidden()
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
            .background(configuration.isPressed ? Color.white.opacity(0.1) : Color.white.opacity(0.06))
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
