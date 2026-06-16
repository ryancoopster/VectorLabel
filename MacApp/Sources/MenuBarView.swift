import SwiftUI
import AppKit

// MARK: – Root menu bar content

/// The dropdown shown when the user clicks the VectorLabel status item.
/// Styled with the shared VectorLabel design tokens (Theme.swift) so it
/// matches the Preferences window and the HTML print/designer UIs.
struct MenuBarView: View {
    @ObservedObject var printerManager  = PrinterManager.shared
    @ObservedObject var recentPrints    = RecentPrintsStore.shared
    @ObservedObject var settings        = AppSettings.shared
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Printers
            printersSection

            vlDivider

            // Active jobs
            if !printerManager.activeJobs.filter({ !$0.isComplete }).isEmpty {
                activeJobsSection
                vlDivider
            }

            // Recent prints
            recentPrintsSection

            vlDivider

            // Actions
            actionsSection
        }
        .frame(width: 320)
        // Fixed width + the popover's preferredContentSize sizing lets the
        // height grow to fit wrapped content so rows are never clipped.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.vlBackground)
    }

    // MARK: – Shared building blocks

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.vlDim)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vlDivider: some View {
        Rectangle()
            .fill(Color.vlBorder)
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.vlSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: – Printers

    private var printersSection: some View {
        Group {
            sectionHeader("Printers")

            if printerManager.printers.isEmpty {
                emptyState("No printers connected")
            } else {
                ForEach(printerManager.printers) { printer in
                    PrinterRow(printer: printer, cassette: printerManager.cassettes[printer.id])
                }
            }
        }
    }

    // MARK: – Active jobs

    private var activeJobsSection: some View {
        Group {
            sectionHeader("Active Jobs")

            ForEach(printerManager.activeJobs.filter { !$0.isComplete }) { job in
                ActiveJobRow(job: job)
            }
        }
    }

    // MARK: – Recent prints

    private var recentPrintsSection: some View {
        Group {
            sectionHeader("Recent Prints")

            if recentPrints.prints.isEmpty {
                emptyState("No recent prints")
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
            MenuActionRow(icon: "square.and.pencil", title: "Open Template Designer", shortcut: "⌘T") {
                appDelegate.openTemplateDesigner()
            }
            .keyboardShortcut("t", modifiers: .command)

            MenuActionRow(icon: "folder", title: "Open Export Folder", shortcut: "⌘E") {
                appDelegate.openExportFolder()
            }
            .keyboardShortcut("e", modifiers: .command)

            MenuActionRow(icon: "gearshape", title: "Preferences…", shortcut: "⌘,") {
                appDelegate.openPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)

            vlDivider

            MenuActionRow(icon: "power", title: "Quit VectorLabel", shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)

            // Build version footer
            Text(appVersionString)
                .font(.system(size: 9))
                .foregroundColor(.vlDim)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
                .padding(.bottom, 8)
        }
    }

    /// App version for the menu footer. Reads the bundle in a real .app build;
    /// falls back to the Info.plist values for the SPM dev binary.
    private var appVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = (info?["CFBundleShortVersionString"] as? String) ?? "1.0.0"
        let build = (info?["CFBundleVersion"] as? String) ?? "dev"
        return "VectorLabel \(short) (build \(build))"
    }
}

// MARK: – Menu action row (icon + title + shortcut, with hover highlight)

struct MenuActionRow: View {
    let icon: String
    let title: String
    let shortcut: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.vlAccent)
                    .frame(width: 24, alignment: .leading)
                Text(title)
                    .font(.system(size: 12))
                    .foregroundColor(.vlLabel)
                Spacer()
                Text(shortcut)
                    .font(.system(size: 10))
                    .foregroundColor(.vlDim)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(hovering ? Color.white.opacity(0.06) : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: – Sub-views

struct PrinterRow: View {
    let printer: PrinterDevice
    var cassette: BradyUSB.SmartCellInfo? = nil

    var statusColor: Color {
        switch printer.status {
        case .ready:   return .vlGreen
        case .busy:    return .vlOrange
        case .offline: return .vlDim
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(printer.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.vlLabel)
                Text("\(printer.serial) · \(printer.status.displayName)")
                    .font(.system(size: 10))
                    .foregroundColor(.vlSecondary)
                if let c = cassette, !c.partNumber.isEmpty {
                    Text("\(c.partNumber) · \(c.supplyRemainingPct)% supply")
                        .font(.system(size: 10))
                        .foregroundColor(.vlAccent)
                }
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
                    .foregroundColor(.vlAccent)
                    .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(job.title)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.vlLabel)
                        .lineLimit(1)
                    Text("\(job.templateName) · \(job.labelCount) labels")
                        .font(.system(size: 10))
                        .foregroundColor(.vlSecondary)
                }

                Spacer()

                if showCancelConfirm {
                    Button("Yes, cancel") {
                        job.requestCancel()
                        showCancelConfirm = false
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.vlRed)
                    .font(.system(size: 10, weight: .medium))

                    Button("Keep") { showCancelConfirm = false }
                        .buttonStyle(.plain)
                        .foregroundColor(.vlSecondary)
                        .font(.system(size: 10))
                } else {
                    Button("Cancel") { showCancelConfirm = true }
                        .buttonStyle(.plain)
                        .foregroundColor(.vlRed)
                        .font(.system(size: 10))
                }
            }

            // Progress bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.vlSurface2)
                        .frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.vlAccent)
                        .frame(width: geo.size.width * CGFloat(job.progress), height: 3)
                }
            }
            .frame(height: 3)

            Text("\(job.completedLabels) of \(job.labelCount)")
                .font(.system(size: 10))
                .foregroundColor(.vlSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}

struct RecentPrintRow: View {
    let recent: RecentPrint
    let onReprint: () -> Void
    @State private var hovering = false

    private var statusIcon: String {
        switch recent.status {
        case .complete:                return "checkmark.circle.fill"
        case .printing:                return "printer.fill"
        case .cancelledBeforePrinting,
             .cancelledMidPrint:        return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch recent.status {
        case .complete:                return .vlGreen
        case .printing:                return .vlAccent
        case .cancelledBeforePrinting,
             .cancelledMidPrint:        return .vlOrange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                // Full title — wraps over as many lines as needed, never clipped.
                Text(recent.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.vlLabel)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(recent.status.displayName) · \(recent.labelCount) label\(recent.labelCount == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundColor(.vlSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("\(recent.dateTimeString) · \(recent.timeAgo)")
                    .font(.system(size: 10))
                    .foregroundColor(.vlDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: onReprint) {
                Text("Reprint")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.vlAccent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.vlAccent.opacity(0.12))
                    .cornerRadius(5)
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hovering = $0 }
    }
}
