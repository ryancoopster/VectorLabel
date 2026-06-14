import SwiftUI
import AppKit

@main
struct CableTronApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Print preview is opened as a separate NSWindow by AppDelegate;
        // SwiftUI's MenuBarExtra provides the persistent status item.
        MenuBarExtra {
            MenuBarContentView()
                .environmentObject(appDelegate.state)
        } label: {
            Image(systemName: appDelegate.state.statusIcon)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(appDelegate.state)
        }
    }
}

/// Shared app state, observed by the menu bar dropdown and settings.
final class AppState: ObservableObject {
    enum Status {
        case idle, printing, done, error(String)
    }

    @Published var status: Status = .idle
    @Published var jobLog: [String] = []
    @Published var exportFolderPath: String = (NSHomeDirectory() as NSString).appendingPathComponent("CableTronExports")
    @Published var templates: [LabelTemplate] = []
    @Published var pendingRecords: [WireRecord] = []

    var statusIcon: String {
        switch status {
        case .idle: return "tag"
        case .printing: return "printer"
        case .done: return "checkmark.circle"
        case .error: return "exclamationmark.triangle"
        }
    }

    func log(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        jobLog.insert("[\(timestamp)] \(message)", at: 0)
        if jobLog.count > 50 { jobLog.removeLast() }
    }
}

struct MenuBarContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        switch state.status {
        case .idle:
            Text("Idle — watching for exports")
        case .printing:
            Text("Printing…")
        case .done:
            Text("Print job complete")
        case .error(let message):
            Text("Error: \(message)")
        }

        Divider()

        ForEach(state.jobLog.prefix(10), id: \.self) { entry in
            Text(entry).font(.caption)
        }

        Divider()

        SettingsLink {
            Text("Settings…")
        }

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let state = AppState()
    private var watcher: ExportWatcher?
    private var printWindowController: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        loadTemplates()

        let url = URL(fileURLWithPath: state.exportFolderPath)
        let watcher = ExportWatcher(folderURL: url)
        watcher.onNewExport = { [weak self] records in
            DispatchQueue.main.async {
                self?.handleNewExport(records)
            }
        }
        watcher.start()
        self.watcher = watcher
    }

    private func handleNewExport(_ records: [WireRecord]) {
        state.pendingRecords = records
        state.log("Received \(records.count) label record(s) for review")
        showPrintPreview()
    }

    private func showPrintPreview() {
        // Bring app to foreground for the print review window
        NSApp.activate(ignoringOtherApps: true)

        let view = PrintPreviewView(
            records: state.pendingRecords,
            templates: state.templates,
            onClose: { [weak self] in
                self?.printWindowController?.close()
                self?.printWindowController = nil
                NSApp.hide(nil)
            },
            onPrint: { [weak self] jobs, partNumber in
                self?.runPrintJobs(jobs, partNumber: partNumber)
                self?.printWindowController?.close()
                self?.printWindowController = nil
                NSApp.hide(nil)
            }
        )

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Print Wire Labels"
        window.contentView = NSHostingView(rootView: view)
        window.center()

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        printWindowController = controller
    }

    private func runPrintJobs(_ jobs: [[UInt8]], partNumber: String) {
        state.status = .printing
        state.log("Sending \(jobs.count) label(s) to printer — load \(partNumber)")

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try BradyUSB.sendJobs(jobs)
                DispatchQueue.main.async {
                    self.state.status = .done
                    self.state.log("Print complete (\(jobs.count) labels)")
                }
            } catch {
                DispatchQueue.main.async {
                    self.state.status = .error("\(error)")
                    self.state.log("Print failed: \(error)")
                }
            }
        }
    }

    private func loadTemplates() {
        // TODO: load saved templates from Application Support
        state.templates = []
    }
}
