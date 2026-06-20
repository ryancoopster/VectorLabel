import SwiftUI
import AppKit
import VectorLabelCore
import PrinterM610
import VectorLabelEngineKit

// MARK: – Root menu bar content

/// The dropdown shown when the user clicks the VectorLabel status item.
/// Styled with the shared VectorLabel design tokens (Theme.swift) so it
/// matches the Preferences window and the HTML print/designer UIs.
struct MenuBarView: View {
    @ObservedObject var printerManager  = PrinterManager.shared
    @ObservedObject var recentPrints    = RecentPrintsStore.shared
    @ObservedObject var settings        = AppSettings.shared
    @EnvironmentObject var appDelegate: AppDelegate
    /// Persisted: hide cancelled prints in the Recent Prints list.
    @AppStorage("hideCancelledPrints") private var hideCancelled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Printers (with each printer's print queue inline)
            printersSection

            vlDivider

            // Recent prints
            recentPrintsSection

            vlDivider

            // Actions
            actionsSection
        }
        .frame(width: 400)
        // Fixed width + the popover's preferredContentSize sizing lets the
        // height grow to fit wrapped content so rows are never clipped.
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.vlBackground)
        // The theme colors are plain global reads (AppSettings.shared.appearance)
        // inside child rows that don't observe AppSettings, so SwiftUI won't
        // re-evaluate them on an appearance flip — text keeps the old colour until
        // hover forces a redraw. Tie the whole tree's identity to the appearance so
        // flipping it rebuilds every row with the right colours.
        .id("\(settings.appearance)-\(settings.systemAppearanceTick)")
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
                    PrinterRow(printer: printer,
                               cassette: printerManager.cassettes[printer.id],
                               jobs: printerManager.jobs(for: printer.id))
                }
            }
        }
    }

    // MARK: – Recent prints

    /// The recent prints shown in the menu, honoring the "hide cancelled" toggle.
    private var displayedRecents: [RecentPrint] {
        guard hideCancelled else { return recentPrints.prints }
        return recentPrints.prints.filter {
            $0.status != .cancelledBeforePrinting && $0.status != .cancelledMidPrint
        }
    }

    private var recentPrintsSection: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                recentPrintsHeader(proxy: proxy)

                if displayedRecents.isEmpty {
                    emptyState(recentPrints.prints.isEmpty ? "No recent prints" : "No prints to show")
                } else {
                    // Full scrollable history (bounded height); the header buttons
                    // jump to top/bottom and clear.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            Color.clear.frame(height: 1).id("vlRecentsTop")
                            ForEach(displayedRecents) { recent in
                                RecentPrintRow(recent: recent) { appDelegate.reprint(recent) }
                            }
                            Color.clear.frame(height: 1).id("vlRecentsBottom")
                        }
                    }
                    .frame(maxHeight: 300)
                }
            }
        }
    }

    private func recentPrintsHeader(proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 2) {
            Text("Recent Prints".uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.vlDim)
            Spacer()
            headerIcon(hideCancelled ? "eye.slash" : "eye",
                       help: hideCancelled ? "Show cancelled prints in the list"
                                           : "Hide cancelled prints from the list") {
                hideCancelled.toggle()
            }
            if !displayedRecents.isEmpty {
                headerIcon("arrow.up.to.line", help: "Scroll to top") {
                    withAnimation { proxy.scrollTo("vlRecentsTop", anchor: .top) }
                }
                headerIcon("arrow.down.to.line", help: "Scroll to bottom") {
                    withAnimation { proxy.scrollTo("vlRecentsBottom", anchor: .bottom) }
                }
            }
            if !recentPrints.prints.isEmpty {
                headerIcon("trash", help: "Clear recent prints", tint: .vlRed) {
                    appDelegate.confirmClearRecents()
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private func headerIcon(_ name: String, help: String, tint: Color = .vlSecondary,
                            _ action: @escaping () -> Void) -> some View {
        // An overlaid NSView owns BOTH the tooltip and the click. AppKit shows a
        // toolTip only for the top-most view under the cursor, so the tooltip must
        // live on the front layer — a SwiftUI Button in front (or a behind view)
        // masks it, which is why .help()/.background tooltips didn't appear here.
        Image(systemName: name)
            .font(.system(size: 11))
            .foregroundColor(tint)
            .frame(width: 22, height: 18)
            .overlay(IconHitView(toolTip: help, action: action))
            .help(help)   // harmless extra
    }

    // MARK: – Actions

    private var actionsSection: some View {
        Group {
            MenuActionRow(icon: "square.and.pencil", title: "Open Template Designer", shortcut: "⌘T") {
                appDelegate.openTemplateDesigner()
            }
            .keyboardShortcut("t", modifiers: .command)

            MenuActionRow(icon: "rectangle.and.pencil.and.ellipsis", title: "Open Custom Designer", shortcut: "") {
                appDelegate.openCustomDesigner()
            }

            MenuActionRow(icon: "folder", title: "Open Export Folder", shortcut: "⌘E") {
                appDelegate.openExportFolder()
            }
            .keyboardShortcut("e", modifiers: .command)

            MenuActionRow(icon: "gearshape", title: "Preferences…", shortcut: "⌘,") {
                appDelegate.openPreferences()
            }
            .keyboardShortcut(",", modifiers: .command)

            // Dark / Auto / Light appearance control, directly under Preferences
            // (it also remains in Preferences).
            AppearanceSlider()
                .padding(.horizontal, 12)
                .padding(.vertical, 4)

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

    /// App version for the menu footer. Uses the compile-time build stamp
    /// (BuildInfo, generated by scripts/stamp-version.sh) so it is correct for
    /// both the SPM dev binary and a packaged .app.
    private var appVersionString: String {
        "VectorLabel \(BuildInfo.display)"
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
            .background(hovering ? Color.vlHover : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: – Sub-views

struct PrinterRow: View {
    let printer: PrinterDevice
    var cassette: CassetteStatus? = nil
    var jobs: [PrintJob] = []

    var statusColor: Color {
        switch printer.status {
        case .ready:   return .vlGreen
        case .busy:    return .vlOrange
        case .offline: return .vlDim
        }
    }

    private var isNetwork: Bool { printer.host?.isEmpty == false }
    /// Top (large) line: "model · name" for a network printer (e.g. "M611 · ryanm611"),
    /// the device name alone for USB.
    private var topLine: String {
        isNetwork ? "\(printer.model) · \(printer.name)" : printer.name
    }
    /// Small (grey) identity line: "IP · serial" for a network printer (once the PICL
    /// serial is known), or "USB · serial" for a USB printer — "USB" sits where the IP
    /// would for a network printer.
    private var subLine: String {
        if isNetwork {
            if let ps = cassette?.printerSerial, !ps.isEmpty { return "\(printer.serial) · \(ps)" }
            return printer.serial   // IP only, until the PICL serial is known
        }
        return printer.serial.isEmpty ? "USB" : "USB · \(printer.serial)"
    }

    /// The printer's driver reports live telemetry (battery/labels/ribbon). M611 yes,
    /// M610 no — gated on the driver capability so it only shows where supported.
    private var showsTelemetry: Bool {
        PrinterModuleRegistry.shared.module(forModel: printer.model)?.capabilities.hasLiveTelemetry ?? false
    }
    /// "Battery 80% · Labels 60% · Ribbon 45%" from the cassette telemetry, or nil if
    /// there's no reading yet. Battery/Ribbon appear only when present; Labels is the
    /// supply-remaining percentage.
    private var telemetryLine: String? {
        guard let c = cassette else { return nil }
        var parts: [String] = []
        if let b = c.batteryPct { parts.append("Battery \(b)%" + (c.acConnected == true ? " ⚡" : "")) }
        parts.append("Labels \(c.supplyRemainingPct)%")
        if let r = c.ribbonRemainingPct { parts.append("Ribbon \(r)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    /// Pre-flight warnings from the printer (printhead open / invalid supply or ribbon),
    /// shown in red so the operator fixes them before printing.
    private var warningLine: String? {
        guard let c = cassette else { return nil }
        var w: [String] = []
        if c.printheadOpen == true     { w.append("printhead open") }
        if c.substrateInvalid == true  { w.append("invalid supply") }
        if c.ribbonInvalid == true     { w.append("invalid ribbon") }
        return w.isEmpty ? nil : "⚠ " + w.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                VStack(alignment: .leading, spacing: 1) {
                    Text(topLine)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.vlLabel)
                    // Small grey identity line: IP · serial for a network printer, else
                    // the serial. (Status is shown by the colored badge + dot, not here.)
                    Text(subLine)
                        .font(.system(size: 10))
                        .foregroundColor(.vlSecondary)
                    if let c = cassette, !c.partNumber.isEmpty {
                        Text(c.partNumber + (c.ribbonPartNumber.map { " · \($0)" } ?? ""))
                            .font(.system(size: 10))
                            .foregroundColor(.vlAccent)
                    }
                    if showsTelemetry, let line = telemetryLine {
                        Text(line)
                            .font(.system(size: 10))
                            .foregroundColor(.vlSecondary)
                    }
                    if let w = warningLine {
                        Text(w)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.vlRed)
                    }
                }

                Spacer()

                Text(printer.status.displayName)
                    .font(.system(size: 11))
                    .foregroundColor(statusColor)

                // Network printers can be removed from the list (a USB printer is
                // physical — it would just reappear on the next scan). Lets the user
                // clear out a disconnected / stale network printer.
                if let host = printer.host, !host.isEmpty {
                    Button {
                        PrinterManager.shared.removeNetworkPrinter(host: host)
                    } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.vlSecondary)
                    .help("Remove this printer")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)

            // Print queue for this printer
            if !jobs.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text("Queue · \(jobs.count)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.vlDim)
                        Spacer()
                        Button("Cancel all") { PrinterManager.shared.cancelAll(for: printer.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.vlRed)
                    }
                    ForEach(jobs) { job in JobRow(job: job) }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 6)
            }
        }
    }
}

/// One queued/printing job under a printer: title, progress bar, %, cancel.
struct JobRow: View {
    @ObservedObject var job: PrintJob

    var body: some View {
        // Detailed (bar + %, per-label count, cancel) when the driver reports progress
        // or the job prints one label at a time; otherwise a coarse "Printing…" row.
        if job.reportsProgress { detailedRow } else { coarseRow }
    }

    private var detailedRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: job.isPrinting ? "printer.fill" : "clock")
                    .font(.system(size: 9))
                    .foregroundColor(job.isPrinting ? .vlAccent : .vlSecondary)
                Text(job.title)
                    .font(.system(size: 11))
                    .foregroundColor(.vlLabel)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(Int(job.progress * 100))%")
                    .font(.system(size: 10))
                    .foregroundColor(.vlSecondary)
                    .monospacedDigit()
                Button { job.requestCancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.vlRed)
                .help("Cancel this print job")
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.vlSurface2).frame(height: 3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(job.isPrinting ? Color.vlAccent : Color.vlDim)
                        .frame(width: geo.size.width * CGFloat(job.progress), height: 3)
                }
            }
            .frame(height: 3)

            Text(job.isPrinting ? "\(job.completedLabels) of \(job.labelCount)"
                                : "Queued · \(job.labelCount) label\(job.labelCount == 1 ? "" : "s")")
                .font(.system(size: 9))
                .foregroundColor(.vlSecondary)
        }
    }

    // Coarse: the printer can't report per-label progress and the job is sent as one
    // full batch, so there's nothing meaningful to animate — just "Printing…" until it
    // finishes (then the job leaves the queue and appears in Recent Prints as done).
    private var coarseRow: some View {
        HStack(spacing: 6) {
            Image(systemName: job.isPrinting ? "printer.fill" : "clock")
                .font(.system(size: 9))
                .foregroundColor(job.isPrinting ? .vlAccent : .vlSecondary)
            Text(job.title)
                .font(.system(size: 11))
                .foregroundColor(.vlLabel)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(job.isPrinting ? "Printing…" : "Queued")
                .font(.system(size: 10))
                .foregroundColor(.vlSecondary)
            // Cancellable only while QUEUED (waiting behind a prior job). Once this
            // job starts printing, the full-job batch has been sent to the printer in
            // one write and can't be interrupted, so the button disappears.
            if !job.isPrinting {
                Button { job.requestCancel() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundColor(.vlRed)
                .help("Cancel this queued print")
            }
        }
    }
}

/// A 3-way Dark / Auto / Light segmented control with high contrast in both themes
/// (selected = white on accent blue; unselected = secondary text). Used in the menu
/// bar and Preferences. "Auto" follows the system appearance.
struct AppearanceSlider: View {
    @ObservedObject var settings = AppSettings.shared
    private let opts: [(value: String, label: String, icon: String)] = [
        ("dark", "Dark", "moon.fill"),
        ("system", "Auto", "circle.lefthalf.filled"),
        ("light", "Light", "sun.max.fill"),
    ]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(opts, id: \.value) { o in
                let on = settings.appearance == o.value
                Button { settings.appearance = o.value } label: {
                    HStack(spacing: 4) {
                        Image(systemName: o.icon).font(.system(size: 10))
                        Text(o.label).font(.system(size: 11, weight: on ? .semibold : .regular))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundColor(on ? .white : .vlSecondary)
                    .background(on ? Color.vlAccent : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.vlSurface2)
        .clipShape(RoundedRectangle(cornerRadius: 8))
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
        case .failed:                  return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch recent.status {
        case .complete:                return .vlGreen
        case .printing:                return .vlAccent
        case .cancelledBeforePrinting,
             .cancelledMidPrint:        return .vlOrange
        case .failed:                  return .vlRed
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
        .background(hovering ? Color.vlHover : Color.clear)
        .onHover { hovering = $0 }
    }
}

// MARK: – AppKit-backed icon button (front-layer tooltip + click)
//
// A top-most NSView that owns the toolTip (so it reliably shows inside the
// menu-bar NSPopover, where SwiftUI's .help() is flaky) AND handles the click,
// since the front layer must be the tooltip owner. The SwiftUI Image behind it
// is purely visual.
private struct IconHitView: NSViewRepresentable {
    let toolTip: String
    let action: () -> Void
    func makeNSView(context: Context) -> NSView {
        let v = HitView(); v.toolTip = toolTip; v.onClick = action; return v
    }
    func updateNSView(_ view: NSView, context: Context) {
        view.toolTip = toolTip
        (view as? HitView)?.onClick = action
    }
    final class HitView: NSView {
        var onClick: (() -> Void)?
        private var pressed = false
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
        override func mouseDown(with event: NSEvent) { pressed = true }
        override func mouseUp(with event: NSEvent) {
            defer { pressed = false }
            if pressed, bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
        }
    }
}
