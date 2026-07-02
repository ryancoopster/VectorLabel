import AppKit
import Darwin
import Foundation

// MARK: – Crash capture (file scope)
//
// The uncaught-exception handler is a C function pointer — it can fire on ANY thread
// and cannot capture context, so its state lives at file scope, not on the
// @MainActor enum.

private var vlCrashAppName = ""
private var vlCrashCaptureInstalled = false

/// Marker written at crash time and offered as a pre-filled report on next launch.
private struct PendingCrashReport: Codable {
    var date: String
    var summary: String
    var details: String
}

private func vlPendingCrashMarkerURL(appName: String) -> URL {
    AppEnvironment.supportRoot.appendingPathComponent("PendingCrashReport-\(appName).json")
}

private func vlHandleUncaughtException(_ exception: NSException) {
    let appName = vlCrashAppName
    let date = ISO8601DateFormatter().string(from: Date())
    let reason = exception.reason ?? "(no reason)"
    let backtrace = exception.callStackSymbols.joined(separator: "\n")
    let details = "name: \(exception.name.rawValue)\nreason: \(reason)\n\n\(backtrace)"

    // Append to ~/Library/Logs/VectorLabel/<appName>-crash.log.
    let dir = VLLog.logDirectory()
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let crashLog = dir.appendingPathComponent("\(appName)-crash.log")
    let entry = "===== \(date) — uncaught exception =====\n\(details)\n\n"
    if let data = entry.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: crashLog) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: crashLog)
        }
    }

    // Pending-report marker, offered by offerPendingCrashReportIfAny() next launch.
    let marker = PendingCrashReport(
        date: date,
        summary: "The app crashed last time (\(exception.name.rawValue))",
        details: details)
    try? FileManager.default.createDirectory(at: AppEnvironment.supportRoot,
                                             withIntermediateDirectories: true)
    if let data = try? JSONEncoder().encode(marker) {
        try? data.write(to: vlPendingCrashMarkerURL(appName: appName), options: .atomic)
    }
    NSLog("[ErrorReporter] uncaught exception captured: %@ — %@", exception.name.rawValue, reason)
}

// MARK: – ErrorReporter

/// User-facing problem reporting for the whole suite: every reported error opens a
/// popup (error summary + user comment + one-time contact capture) that files an
/// issue in the PRIVATE ryancoopster/VectorLabel-reports repo via the GitHub REST
/// API. Reports attach system info, contact info, the Engine's published printer
/// status, and the suite's recent combined log output (see VLLog).
@MainActor
public enum ErrorReporter {

    // MARK: Configuration (delivery token)

    /// True when a delivery token is available. When false the popup still opens but
    /// Submit is replaced by a "Reporting isn't configured in this build" caption +
    /// a "Copy Report" button that copies the full report markdown to the clipboard.
    public static var isConfigured: Bool { deliveryToken != nil }

    /// Per-build bundle resource written by scripts/package-suite.sh from the
    /// VL_REPORTS_TOKEN secret — never in git. Missing/empty → unconfigured.
    private static let deliveryToken: String? = {
        guard let url = Bundle.main.url(forResource: "VLReportingToken", withExtension: nil),
              let raw = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }()

    // MARK: App-name mapping

    /// The suite app this process is, derived from the bundle-id suffix (falling back
    /// to the executable name for bare `swift run` binaries with no Info.plist).
    public nonisolated static func currentAppName() -> String {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id.hasSuffix(".autoprint") { return "Auto Print" }
        if id.hasSuffix(".templatedesigner") { return "Template Designer" }
        if id.hasSuffix(".customdesigner") { return "Custom Designer" }
        if id.hasSuffix(".engine") { return "Engine" }
        let proc = ProcessInfo.processInfo.processName
        if proc.contains("AutoPrint") { return "Auto Print" }
        if proc.contains("TemplateDesigner") { return "Template Designer" }
        if proc.contains("CustomDesigner") { return "Custom Designer" }
        return "Engine"
    }

    /// "Auto Print" → "auto-print" (issue label).
    static func appSlug(_ appName: String) -> String {
        appName.lowercased().replacingOccurrences(of: " ", with: "-")
    }

    // MARK: Entry points

    /// One popup at a time; presentReport() drops (never queues) while one is up.
    private static var activePanel: ReportPanel?
    private static var lastPresentedTitle = ""
    private static var lastPresentedAt = Date.distantPast

    /// Manual report (Engine menu): popup with an empty, required description.
    public static func presentManualReport(appName: String) {
        if let existing = activePanel {
            NSApp.activate(ignoringOtherApps: true)
            existing.orderFront()
            return
        }
        openPanel(kind: .manual, title: "", details: "", appName: appName)
    }

    /// Auto-detected error: popup pre-filled with the error. Throttled: drops if an
    /// identical title was popped <60s ago or a popup is already on screen.
    public static func presentReport(title: String, details: String, appName: String) {
        if activePanel != nil {
            NSLog("[ErrorReporter] dropped report “%@” — a report popup is already on screen", title)
            return
        }
        if title == lastPresentedTitle, Date().timeIntervalSince(lastPresentedAt) < 60 {
            NSLog("[ErrorReporter] dropped report “%@” — identical report popped <60s ago", title)
            return
        }
        lastPresentedTitle = title
        lastPresentedAt = Date()
        openPanel(kind: .auto, title: title, details: details, appName: appName)
    }

    /// Standard error alert (OK + "Report…") replacing bespoke NSAlert error sites.
    /// Sheet on `window` if non-nil, else app-modal (activated first — the Engine and
    /// Auto Print run as .accessory apps, whose modals otherwise open behind).
    public static func showErrorAlert(title: String, message: String, details: String?,
                                      in window: NSWindow?, appName: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Report…")
        if let window {
            alert.beginSheetModal(for: window) { response in
                guard response == .alertSecondButtonReturn else { return }
                Task { @MainActor in
                    ErrorReporter.presentReport(title: title, details: details ?? message,
                                                appName: appName)
                }
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertSecondButtonReturn {
                presentReport(title: title, details: details ?? message, appName: appName)
            }
        }
    }

    /// Thread-safe entry for non-main contexts (EngineKit print thread): hops to main.
    public nonisolated static func reportAsync(title: String, details: String, appName: String) {
        Task { @MainActor in
            ErrorReporter.presentReport(title: title, details: details, appName: appName)
        }
    }

    // MARK: Crash capture

    /// NSSetUncaughtExceptionHandler that appends name/reason/backtrace to
    /// ~/Library/Logs/VectorLabel/<appName>-crash.log AND writes a pending-report
    /// marker JSON. Safe to call from any thread; install once at launch.
    public nonisolated static func installCrashCapture(appName: String) {
        vlCrashAppName = appName
        guard !vlCrashCaptureInstalled else { return }
        vlCrashCaptureInstalled = true
        NSSetUncaughtExceptionHandler(vlHandleUncaughtException)
    }

    /// At launch: if a pending crash marker exists, offer a pre-filled report for it
    /// and delete the marker. Call late in launch (after the UI is up).
    public static func offerPendingCrashReportIfAny(appName: String) {
        let url = vlPendingCrashMarkerURL(appName: appName)
        guard let data = try? Data(contentsOf: url),
              let marker = try? JSONDecoder().decode(PendingCrashReport.self, from: data) else { return }
        try? FileManager.default.removeItem(at: url)
        presentReport(title: marker.summary,
                      details: "Crashed at \(marker.date)\n\n\(marker.details)",
                      appName: appName)
    }

    // MARK: Panel plumbing

    private static func openPanel(kind: ReportPanel.Kind, title: String, details: String,
                                  appName: String) {
        // .accessory apps: activate first or the panel opens behind the frontmost app.
        NSApp.activate(ignoringOtherApps: true)
        let panel = ReportPanel(kind: kind, errorTitle: title, details: details, appName: appName)
        activePanel = panel
        panel.show()
    }

    fileprivate static func panelDidClose(_ panel: ReportPanel) {
        if activePanel === panel { activePanel = nil }
    }

    // MARK: GitHub client

    private static let issuesURLString =
        "https://api.github.com/repos/ryancoopster/VectorLabel-reports/issues"

    /// POST the issue. Completion always hops to the main actor (UpdateChecker's
    /// extract-Sendable-pieces-then-hop pattern).
    static func submit(issueTitle: String, body: String, labels: [String],
                       completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard let token = deliveryToken, let url = URL(string: issuesURLString) else {
            completion(.failure(NSError(domain: "VLErrorReporter", code: -1, userInfo:
                [NSLocalizedDescriptionKey: "Reporting isn’t configured in this build."])))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("VectorLabel/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = ["title": issueTitle, "body": body, "labels": labels]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                if let error {
                    completion(.failure(error))
                } else if (200..<300).contains(status) {
                    completion(.success(()))
                } else {
                    completion(.failure(NSError(domain: "VLErrorReporter", code: status, userInfo:
                        [NSLocalizedDescriptionKey: "GitHub returned HTTP \(status)."])))
                }
            }
        }
        task.resume()
    }

    // MARK: Report body (GitHub markdown, total ≤ 60000 chars)

    private static let maxBodyLength = 60_000
    /// Individual caps so the log tail (trimmed last-first) always gets some budget.
    private static let maxSectionLength = 20_000

    static func buildReportBody(errorTitle: String, details: String, comment: String,
                                contact: ReportContact, appName: String) -> String {
        var sections: [String] = []

        let trimmedComment = cap(comment.trimmingCharacters(in: .whitespacesAndNewlines))
        sections.append("## User comment\n\n" + (trimmedComment.isEmpty ? "_(none)_" : trimmedComment))

        if !errorTitle.isEmpty || !details.isEmpty {
            var err = "## Error\n\n**\(errorTitle)**"
            let d = cap(details.trimmingCharacters(in: .whitespacesAndNewlines))
            if !d.isEmpty { err += "\n\n```\n\(d)\n```" }
            sections.append(err)
        }

        sections.append("""
        ## System

        - App: \(appName)
        - Version: \(BuildInfo.display)
        - Beta: \(AppEnvironment.isBeta ? "yes" : "no")
        - macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        - Hardware: \(hardwareModel())
        """)

        sections.append("""
        ## Contact

        - Name: \(contact.name)
        - Email: \(contact.email)
        - Phone: \(contact.phone.isEmpty ? "—" : contact.phone)
        """)

        sections.append(printersSection())

        let head = sections.joined(separator: "\n\n")
        return head + logSection(headLength: head.count)
    }

    private static func cap(_ s: String) -> String {
        s.count > maxSectionLength ? String(s.prefix(maxSectionLength)) + "\n… (truncated)" : s
    }

    /// One-shot read of the Engine-published printer status (staleness noted via its
    /// updatedAt stamp — the Engine may not even be running when a designer reports).
    private static func printersSection() -> String {
        guard let status = PrintQueue().readStatus() else {
            return "## Printers\n\nEngine status unavailable."
        }
        var lines = ["## Printers", ""]
        if !status.updatedAt.isEmpty {
            lines.append("_Status as of \(status.updatedAt)"
                + (status.engineRunning ? "_" : " (engine not running)_"))
            lines.append("")
        }
        if status.printers.isEmpty { lines.append("No printers connected.") }
        for p in status.printers {
            var line = "- \(p.name.isEmpty ? p.model : p.name) (\(p.model)"
            if !p.serial.isEmpty { line += ", s/n \(p.serial)" }
            line += ") — \(p.status)"
            if let c = p.cassette {
                line += "; cassette \(c.partNumber) (\(c.labelWidthMils)×\(c.labelHeightMils) mil)"
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Fenced tail of the shared suite log — the first thing trimmed when the body
    /// would exceed the budget.
    private static func logSection(headLength: Int) -> String {
        let path = VLLog.currentLogPath
        var tail = VLLog.recentTail(maxBytes: 40_000)
        if tail.isEmpty { return "\n\n## Log\n\n_No log output captured (\(path))._" }
        let prefix = "\n\n## Log\n\n_Tail of the shared suite log \(path)"
            + " (all four apps, lines tagged per app):_\n\n```\n"
        let suffix = "\n```"
        let budget = maxBodyLength - headLength - prefix.count - suffix.count
        if budget <= 0 { return "\n\n## Log\n\n_Omitted — report at the size limit._" }
        if tail.count > budget { tail = String(tail.suffix(budget)) }
        return prefix + tail + suffix
    }

    private static func hardwareModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return "unknown" }
        return String(cString: buf)
    }
}

// MARK: – Report popup

/// The report popup: a floating titled NSPanel (the UpdateChecker download-panel
/// precedent) rather than a nested NSAlert — validation failures keep it open, the
/// async submit updates it in place, and the contact section can swap between the
/// "Reporting as …" summary line and the editable fields.
@MainActor
private final class ReportPanel: NSObject, NSWindowDelegate {

    enum Kind { case manual, auto }

    private let kind: Kind
    private let errorTitle: String
    private let details: String
    private let appName: String

    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
                                styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private let commentView = NSTextView()
    private let nameField = NSTextField(string: "")
    private let emailField = NSTextField(string: "")
    private let phoneField = NSTextField(string: "")
    private var contactSummaryRow: NSStackView?
    private var contactFieldsBox: NSStackView?
    private var sendButton: NSButton?
    private var storedContact: ReportContact?

    private static let contentWidth: CGFloat = 420

    init(kind: Kind, errorTitle: String, details: String, appName: String) {
        self.kind = kind
        self.errorTitle = errorTitle
        self.details = details
        self.appName = appName
        self.storedContact = ReportContactStore.load()
        super.init()
        panel.title = "Report a Problem"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false   // .accessory apps deactivate freely — keep the popup up
        panel.delegate = self
        buildContent()
    }

    func show() {
        sizeToFit()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(commentView)
    }

    func orderFront() { panel.makeKeyAndOrderFront(nil) }

    func windowWillClose(_ notification: Notification) {
        ErrorReporter.panelDidClose(self)
    }

    // MARK: Content

    private func buildContent() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(labelWithString: "Report a problem to the developer")
        heading.font = .boldSystemFont(ofSize: 13)
        stack.addArrangedSubview(heading)

        let subtitle = NSTextField(wrappingLabelWithString:
            kind == .auto ? errorTitle
                          : "Describe the problem and it will be sent with diagnostic info.")
        subtitle.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(subtitle)
        subtitle.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true

        if kind == .auto, !details.isEmpty, details != errorTitle {
            let summary = NSTextField(wrappingLabelWithString: details)
            summary.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
            summary.textColor = .secondaryLabelColor
            summary.maximumNumberOfLines = 3
            summary.cell?.truncatesLastVisibleLine = true
            stack.addArrangedSubview(summary)
            summary.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        }

        let commentLabel = NSTextField(labelWithString:
            kind == .manual ? "Describe what you were doing… (required)"
                            : "Describe what you were doing… (optional)")
        commentLabel.font = .systemFont(ofSize: 11)
        commentLabel.textColor = .secondaryLabelColor
        stack.addArrangedSubview(commentLabel)

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        commentView.frame = NSRect(x: 0, y: 0, width: Self.contentWidth, height: 120)
        commentView.isRichText = false
        commentView.font = .systemFont(ofSize: 12)
        commentView.isAutomaticQuoteSubstitutionEnabled = false
        commentView.textContainerInset = NSSize(width: 4, height: 4)
        commentView.autoresizingMask = [.width]
        commentView.isVerticallyResizable = true
        commentView.minSize = NSSize(width: 0, height: 120)
        commentView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                     height: CGFloat.greatestFiniteMagnitude)
        commentView.textContainer?.widthTracksTextView = true
        scroll.documentView = commentView
        stack.addArrangedSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: Self.contentWidth),
            scroll.heightAnchor.constraint(equalToConstant: 120),
        ])

        buildContactSection(into: stack)
        buildButtonRow(into: stack)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        ])
        panel.contentView = content
    }

    private func buildContactSection(into stack: NSStackView) {
        // Summary row: "Reporting as <name> · <email>"  [Edit]
        let summaryLabel = NSTextField(labelWithString: storedContact.map {
            "Reporting as \($0.name) · \($0.email)" } ?? "")
        summaryLabel.font = .systemFont(ofSize: 12)
        summaryLabel.lineBreakMode = .byTruncatingTail
        let edit = NSButton(title: "Edit", target: self, action: #selector(editContactPressed))
        edit.bezelStyle = .rounded
        edit.controlSize = .small
        let summaryRow = NSStackView(views: [summaryLabel, edit])
        summaryRow.orientation = .horizontal
        summaryRow.spacing = 8
        stack.addArrangedSubview(summaryRow)
        contactSummaryRow = summaryRow

        // Editable fields (first run, or after Edit).
        let fields = NSStackView()
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.spacing = 6
        fields.addArrangedSubview(fieldRow("Name:", nameField, placeholder: "Required"))
        fields.addArrangedSubview(fieldRow("Email:", emailField, placeholder: "Required"))
        fields.addArrangedSubview(fieldRow("Phone:", phoneField, placeholder: "Optional"))
        let caption = NSTextField(wrappingLabelWithString:
            "Stored on this Mac and included with your reports so the developer can follow up.")
        caption.font = .systemFont(ofSize: 10)
        caption.textColor = .secondaryLabelColor
        fields.addArrangedSubview(caption)
        caption.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        stack.addArrangedSubview(fields)
        contactFieldsBox = fields

        if let c = storedContact {
            nameField.stringValue = c.name
            emailField.stringValue = c.email
            phoneField.stringValue = c.phone
            fields.isHidden = true
        } else {
            summaryRow.isHidden = true
        }
    }

    private func fieldRow(_ label: String, _ field: NSTextField, placeholder: String) -> NSStackView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 12)
        l.alignment = .right
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 12)
        let row = NSStackView(views: [l, field])
        row.orientation = .horizontal
        row.spacing = 8
        NSLayoutConstraint.activate([
            l.widthAnchor.constraint(equalToConstant: 52),
            field.widthAnchor.constraint(equalToConstant: Self.contentWidth - 60),
        ])
        return row
    }

    private func buildButtonRow(into stack: NSStackView) {
        let row = NSStackView()
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(wrappingLabelWithString: ErrorReporter.isConfigured
            ? "Sent privately to the VectorLabel developer."
            : "Reporting isn’t configured in this build")
        footer.font = .systemFont(ofSize: 10)
        footer.textColor = .secondaryLabelColor
        footer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addView(footer, in: .leading)

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Esc cancels too
        row.addView(cancel, in: .trailing)

        if ErrorReporter.isConfigured {
            let send = NSButton(title: "Send Report", target: self, action: #selector(sendPressed))
            send.bezelStyle = .rounded
            send.keyEquivalent = "\r"
            sendButton = send
            row.addView(send, in: .trailing)
        } else {
            let copy = NSButton(title: "Copy Report", target: self, action: #selector(copyPressed))
            copy.bezelStyle = .rounded
            copy.keyEquivalent = "\r"
            row.addView(copy, in: .trailing)
        }

        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
    }

    private func sizeToFit() {
        guard let content = panel.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let topLeft = NSPoint(x: panel.frame.minX, y: panel.frame.maxY)
        panel.setContentSize(content.fittingSize)
        panel.setFrameTopLeftPoint(topLeft)
    }

    // MARK: Actions

    @objc private func editContactPressed() {
        contactSummaryRow?.isHidden = true
        contactFieldsBox?.isHidden = false
        sizeToFit()
        panel.makeFirstResponder(nameField)
    }

    @objc private func cancelPressed() { panel.close() }

    /// Name/email (when the fields are showing) — beep + focus the missing one.
    /// Returns nil when invalid.
    private func validatedContact() -> ReportContact? {
        guard let fields = contactFieldsBox, !fields.isHidden else { return storedContact }
        let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        let email = emailField.stringValue.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { NSSound.beep(); panel.makeFirstResponder(nameField); return nil }
        if email.isEmpty { NSSound.beep(); panel.makeFirstResponder(emailField); return nil }
        return ReportContact(name: name, email: email,
                             phone: phoneField.stringValue.trimmingCharacters(in: .whitespaces))
    }

    /// Comment text; beeps + focuses the box when a manual report leaves it empty.
    private func validatedComment() -> String? {
        let comment = commentView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .manual, comment.isEmpty {
            NSSound.beep(); panel.makeFirstResponder(commentView); return nil
        }
        return comment
    }

    private func issueTitle(comment: String) -> String {
        if kind == .auto { return errorTitle }
        let firstLine = comment.split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return firstLine.isEmpty ? "User report" : "User report: \(String(firstLine.prefix(80)))"
    }

    @objc private func sendPressed() {
        guard let contact = validatedContact(), let comment = validatedComment() else { return }
        ReportContactStore.save(contact)
        storedContact = contact
        let body = ErrorReporter.buildReportBody(
            errorTitle: kind == .auto ? errorTitle : "",
            details: kind == .auto ? details : "",
            comment: comment, contact: contact, appName: appName)
        sendButton?.isEnabled = false
        sendButton?.title = "Sending…"
        // Strong self on purpose: the panel must survive until the reply lands.
        ErrorReporter.submit(issueTitle: issueTitle(comment: comment), body: body,
                             labels: [kind == .auto ? "auto" : "manual",
                                      ErrorReporter.appSlug(appName)]) { result in
            self.finishSubmit(result, body: body)
        }
    }

    private func finishSubmit(_ result: Result<Void, Error>, body: String) {
        switch result {
        case .success:
            flip(to: "Report sent — thank you.")
        case .failure(let error):
            sendButton?.isEnabled = true
            sendButton?.title = "Send Report"
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn’t send the report"
            alert.informativeText = "\(error.localizedDescription)\n\n"
                + "Copy the report to the clipboard so nothing is lost, then email it to the developer."
            alert.addButton(withTitle: "Copy Report")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: panel) { response in
                guard response == .alertFirstButtonReturn else { return }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(body, forType: .string)
            }
        }
    }

    /// Unconfigured build: copy the full report markdown instead of sending.
    @objc private func copyPressed() {
        guard let comment = validatedComment() else { return }
        // Keep the one-time contact capture working even without a token, but don't
        // force it — nothing is transmitted.
        let contact: ReportContact
        if let fields = contactFieldsBox, !fields.isHidden {
            contact = ReportContact(
                name: nameField.stringValue.trimmingCharacters(in: .whitespaces),
                email: emailField.stringValue.trimmingCharacters(in: .whitespaces),
                phone: phoneField.stringValue.trimmingCharacters(in: .whitespaces))
            if !contact.name.isEmpty && !contact.email.isEmpty { ReportContactStore.save(contact) }
        } else {
            contact = storedContact ?? ReportContact(name: "", email: "", phone: "")
        }
        let body = ErrorReporter.buildReportBody(
            errorTitle: kind == .auto ? errorTitle : "",
            details: kind == .auto ? details : "",
            comment: comment, contact: contact, appName: appName)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(body, forType: .string)
        flip(to: "Report copied to the clipboard.")
    }

    /// Replace the whole panel with a brief confirmation, then close on its own.
    private func flip(to message: String) {
        let content = NSView()
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13)
        label.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            label.topAnchor.constraint(equalTo: content.topAnchor, constant: 32),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -32),
            content.widthAnchor.constraint(equalToConstant: 460),
        ])
        panel.contentView = content
        sizeToFit()
        let panel = self.panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { panel.close() }
    }
}
