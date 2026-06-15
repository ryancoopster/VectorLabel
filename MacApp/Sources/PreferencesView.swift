import SwiftUI
import AppKit

/// Full Preferences window — matches the spec from our design session.
struct PreferencesView: View {
    @ObservedObject var settings = AppSettings.shared
    @ObservedObject var recentPrints = RecentPrintsStore.shared

    @State private var showResetConfirm = false
    @State private var showClearRecentConfirm = false

    var body: some View {
        TabView {
            exportTab
                .tabItem { Label("Export", systemImage: "arrow.down.doc") }

            printingTab
                .tabItem { Label("Printing", systemImage: "printer") }

            templatesTab
                .tabItem { Label("Templates", systemImage: "doc.richtext") }

            recentTab
                .tabItem { Label("Recent Prints", systemImage: "clock") }

            printersTab
                .tabItem { Label("Printers", systemImage: "cable.connector") }

            advancedTab
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
        }
        .padding(20)
        .frame(width: 520, height: 380)
    }

    // MARK: – Export tab

    private var exportTab: some View {
        Form {
            Section("Watch Folder") {
                HStack {
                    Text(settings.watchFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Browse…") { browseWatchFolder() }
                }
                Text("The app watches ~/[folder]/Exports/ and all project subfolders within it.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("New Export Behaviour") {
                Toggle("Auto-open print window when export detected", isOn: $settings.autoOpenPrintWindow)
            }

            Section("Export History") {
                HStack {
                    Text("Exports to keep per project")
                    Spacer()
                    Stepper("\(settings.maxExportsPerProject)", value: $settings.maxExportsPerProject, in: 1...100)
                        .frame(width: 140)
                }
                Text("Oldest exports are pruned using the date code in the filename, not file system metadata.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: – Printing tab

    private var printingTab: some View {
        Form {
            Section("Default Print Range") {
                Picker("Default range", selection: $settings.defaultPrintRange) {
                    Text("All labels").tag("all")
                    Text("Selected labels").tag("selected")
                    Text("Custom range").tag("range")
                }
                .pickerStyle(.segmented)
            }

            Section("Hardware") {
                HStack {
                    Text("Inter-label delay")
                    Spacer()
                    HStack(spacing: 4) {
                        Stepper("", value: $settings.interLabelDelayMs, in: 0...2000, step: 10)
                        Text("\(settings.interLabelDelayMs) ms")
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 56)
                    }
                }
                Text("Delay between consecutive label jobs. Increase if the printer drops labels.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: – Templates tab

    private var templatesTab: some View {
        Form {
            Section("Templates Folder") {
                HStack {
                    Text(settings.templatesFolderPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Browse…") { browseTemplatesFolder() }
                }
                Text("Templates saved as .vlt.json from the Template Designer are stored here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: – Recent prints tab

    private var recentTab: some View {
        Form {
            Section("History") {
                Picker("Jobs to keep", selection: $settings.recentPrintsCount) {
                    Text("3").tag(3)
                    Text("5").tag(5)
                    Text("10").tag(10)
                }
                .pickerStyle(.segmented)
            }

            Section {
                Button("Clear Recent Print History…") {
                    showClearRecentConfirm = true
                }
                .foregroundColor(.red)
                .confirmationDialog(
                    "Clear all \(recentPrints.prints.count) recent print records?",
                    isPresented: $showClearRecentConfirm,
                    titleVisibility: .visible
                ) {
                    Button("Clear History", role: .destructive) { recentPrints.clear() }
                }
            }
        }
    }

    // MARK: – Printers tab

    private var printersTab: some View {
        Form {
            Section("USB Device List") {
                Button("Refresh Connected Printers") {
                    Task { @MainActor in PrinterManager.shared.scanNow() }
                }
                Text("Printers are scanned automatically every 5 seconds. Use this if a newly connected printer isn't appearing.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Brady M611 Product ID Override") {
                HStack {
                    Text("0x")
                        .foregroundColor(.secondary)
                    TextField("010C", text: $settings.m611ProductIDOverride)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 60)
                }
                Text("The M611 PID hasn't been confirmed. If your M611 isn't detected, connect it, run system_profiler SPUSBDataType in Terminal, find the Brady entry and enter its idProduct hex value here.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: – Advanced tab

    private var advancedTab: some View {
        Form {
            Section("App Behaviour") {
                Toggle("Show VectorLabel in Dock", isOn: $settings.showInDock)
                Text("By default VectorLabel runs as a menu bar app only. Enable this to also show it in the Dock.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section {
                Button("Reset All Settings to Defaults…") {
                    showResetConfirm = true
                }
                .foregroundColor(.red)
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

    // MARK: – Folder pickers

    private func browseWatchFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Watch Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.watchFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.watchFolderPath = url.path
        }
    }

    private func browseTemplatesFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Select Templates Folder"
        panel.directoryURL = URL(fileURLWithPath: settings.templatesFolderPath)
        if panel.runModal() == .OK, let url = panel.url {
            settings.templatesFolderPath = url.path
        }
    }
}

// MARK: – PrinterManager extension for manual scan

extension PrinterManager {
    func scanNow() { Task { @MainActor in self.scanNow() } }
}
