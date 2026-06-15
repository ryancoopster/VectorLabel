import SwiftUI
import AppKit

// MARK: – Root menu bar content

/// The full dropdown that appears when the user clicks the VectorLabel status item.
/// Matches VectorLabel-MenuBar.html exactly.
struct MenuBarView: View {
    @ObservedObject var printerManager  = PrinterManager.shared
    @ObservedObject var recentPrints    = RecentPrintsStore.shared
    @ObservedObject var settings        = AppSettings.shared
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        // Printers
        printersSection

        Divider()

        // Active jobs
        if !printerManager.activeJobs.filter({ !$0.isComplete }).isEmpty {
            activeJobsSection
            Divider()
        }

        // Recent prints
        recentPrintsSection

        Divider()

        // Actions
        actionsSection
    }

    // MARK: – Printers

    private var printersSection: some View {
        Group {
            Text("Printers")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            if printerManager.printers.isEmpty {
                Text("No printers connected")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                ForEach(printerManager.printers) { printer in
                    PrinterRow(printer: printer)
                }
            }
        }
    }

    // MARK: – Active jobs

    private var activeJobsSection: some View {
        Group {
            Text("Active Jobs")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            ForEach(printerManager.activeJobs.filter { !$0.isComplete }) { job in
                ActiveJobRow(job: job)
            }
        }
    }

    // MARK: – Recent prints

    private var recentPrintsSection: some View {
        Group {
            Text("Recent Prints")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)

            if recentPrints.prints.isEmpty {
                Text("No recent prints")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
            } else {
                ForEach(recentPrints.prints.prefix(settings.recentPrintsCount)) { recent in
                    RecentPrintRow(recent: recent) {
                        appDelegate.openReprint(recent)
                    }
                }
            }
        }
    }

    // MARK: – Actions

    private var actionsSection: some View {
        Group {
            Button {
                appDelegate.openTemplateDesigner()
            } label: {
                HStack {
                    Image(systemName: "square.and.pencil")
                        .frame(width: 18)
                    Text("Open Template Designer")
                    Spacer()
                    Text("⌘T")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }
            }
            .keyboardShortcut("t", modifiers: .command)

            Button {
                appDelegate.openExportFolder()
            } label: {
                HStack {
                    Image(systemName: "folder")
                        .frame(width: 18)
                    Text("Open Export Folder")
                    Spacer()
                    Text("⌘E")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }
            }
            .keyboardShortcut("e", modifiers: .command)

            Button {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            } label: {
                HStack {
                    Image(systemName: "gearshape")
                        .frame(width: 18)
                    Text("Preferences…")
                    Spacer()
                    Text("⌘,")
                        .foregroundColor(.secondary)
                        .font(.system(size: 10))
                }
            }
            .keyboardShortcut(",", modifiers: .command)

            Divider()

            Button("Quit VectorLabel") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

// MARK: – Sub-views

struct PrinterRow: View {
    let printer: PrinterDevice

    var statusColor: Color {
        switch printer.status {
        case .ready:   return .green
        case .busy:    return .orange
        case .offline: return Color(white: 0.5)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
                .opacity(printer.status == .busy ? 1.0 : 1.0)  // pulse handled separately

            VStack(alignment: .leading, spacing: 1) {
                Text(printer.name)
                    .font(.system(size: 12, weight: .medium))
                Text("\(printer.serial) · \(printer.status.displayName)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(printer.status.displayName)
                .font(.system(size: 11))
                .foregroundColor(statusColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}

struct ActiveJobRow: View {
    @ObservedObject var job: PrintJob
    @State private var showCancelConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "printer.fill")
                    .foregroundColor(.blue)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text("\(job.templateName) · \(job.labelCount) labels")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }

                Spacer()

                if showCancelConfirm {
                    Button("Yes, cancel") {
                        job.requestCancel()
                        showCancelConfirm = false
                    }
                    .foregroundColor(.red)
                    .font(.system(size: 10))

                    Button("Keep") { showCancelConfirm = false }
                        .font(.system(size: 10))
                } else {
                    Button("Cancel") { showCancelConfirm = true }
                        .foregroundColor(.red)
                        .font(.system(size: 10))
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.white.opacity(0.1))
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue)
                        .frame(width: geo.size.width * CGFloat(job.progress), height: 3)
                }
            }
            .frame(height: 3)

            Text("\(job.completedLabels) of \(job.labelCount)")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct RecentPrintRow: View {
    let recent: RecentPrint
    let onReprint: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(recent.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text("\(recent.labelCount) labels · \(recent.templateName) · \(recent.timeAgo)")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Reprint") { onReprint() }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.accentColor)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }
}
