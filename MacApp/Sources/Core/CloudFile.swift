import AppKit
import Darwin

/// Online-only ("cloud placeholder") file handling.
///
/// Dropbox / OneDrive / iCloud can leave a file on disk as an APFS **dataless** stub —
/// reading it blocks (or fails) until the provider downloads the bytes. Every place the
/// app consumes a user-chosen file first calls `materialize(_:for:whenReady:)`: a
/// synchronous no-op for fully-local files, otherwise a small cancellable
/// "Downloading…" panel until the provider delivers the data.
///
/// Call-site pattern (the completion always runs on the main actor):
///
///     CloudFile.materialize([url], for: window) { result in
///         guard case .ready = result else { return }   // cancelled → back where you were
///         …original open/import/read code…
///     }
public enum CloudFile {

    public enum MaterializeResult {
        case ready
        case cancelled
        case failed(Error)
    }

    // MARK: – Placeholder detection

    /// APFS dataless flag (`SF_DATALESS`, sys/stat.h) — set on File Provider stubs.
    /// Defined locally in case the SDK doesn't surface the constant to Swift.
    private static let sfDataless: UInt32 = 0x4000_0000

    /// True when `url` is an online-only placeholder. Checks BOTH signals: stat
    /// `st_flags & SF_DATALESS` (File Provider — Dropbox/OneDrive/modern iCloud) and the
    /// classic iCloud `ubiquitousItemDownloadingStatus != .current` resource value
    /// (nil for non-iCloud files). A stat failure is NOT a placeholder — the caller's
    /// normal read-error handling covers unreadable files.
    public static func isPlaceholder(_ url: URL) -> Bool {
        var st = stat()
        if stat(url.path, &st) == 0, (st.st_flags & sfDataless) != 0 { return true }
        if let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
           let status = values.ubiquitousItemDownloadingStatus, status != .current {
            return true
        }
        return false
    }

    // MARK: – Materialization

    /// Ensure every URL in `urls` is fully local, then call `completion` — always on the
    /// main actor. Fast path: nothing is a placeholder → `completion(.ready)` runs
    /// synchronously before this returns (zero UI flash for the all-local case).
    /// Otherwise ONE small panel (spinner + "Downloading “name”…" + "file i of n" when
    /// n > 1 + Cancel) is shown — as a sheet on `window` when given, else as a centered
    /// floating panel — while the files download one by one. Cancel →
    /// `completion(.cancelled)`; a download error → `completion(.failed)` after an
    /// NSAlert, so call sites keep the one-line `guard case .ready` shape.
    @MainActor
    public static func materialize(_ urls: [URL], for window: NSWindow?,
                                   whenReady completion: @escaping @MainActor (MaterializeResult) -> Void) {
        let pending = urls.filter(isPlaceholder)
        guard !pending.isEmpty else { completion(.ready); return }
        let session = DownloadSession(pending: pending, window: window, completion: completion)
        sessions.append(session)   // keep it alive; it removes itself on finish
        session.begin()
    }

    /// In-flight download-waits (the caller holds no reference to its session).
    @MainActor private static var sessions: [DownloadSession] = []

    /// POSIX errno → Error, for open/read failures on the trigger thread.
    private static func posixError(_ code: Int32) -> Error {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }

    /// Error captured by the detached trigger thread, read by the background poll loop.
    private final class ErrorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Error?
        var error: Error? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    // MARK: – One download-wait (panel UI + trigger + poll loop)

    @MainActor
    private final class DownloadSession: NSObject {
        private let pending: [URL]
        private weak var hostWindow: NSWindow?
        private let completion: @MainActor (MaterializeResult) -> Void

        private let panel: NSPanel
        private let nameLabel = NSTextField(labelWithString: "")
        private let countLabel = NSTextField(labelWithString: "")
        private var currentIndex = 0
        private var finished = false

        init(pending: [URL], window: NSWindow?,
             completion: @escaping @MainActor (MaterializeResult) -> Void) {
            self.pending = pending
            self.hostWindow = window
            self.completion = completion
            self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            super.init()
            buildPanel()
        }

        func begin() {
            // The designer/print windows are .nonactivatingPanels — activate first (the
            // presentImportError convention) or the sheet can sit behind / unclickable.
            NSApp.activate(ignoringOtherApps: true)
            if let host = hostWindow {
                host.beginSheet(panel)
            } else {
                panel.level = .floating
                panel.center()
                panel.makeKeyAndOrderFront(nil)
            }
            startFile(0)
        }

        // MARK: Panel UI

        private func buildPanel() {
            panel.title = "Downloading"
            panel.isReleasedWhenClosed = false

            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.isIndeterminate = true
            spinner.startAnimation(nil)

            nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
            nameLabel.lineBreakMode = .byTruncatingMiddle
            countLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            countLabel.textColor = .secondaryLabelColor
            countLabel.isHidden = pending.count == 1   // "file i of n" only when n > 1

            let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPressed))
            cancel.bezelStyle = .rounded
            cancel.keyEquivalent = "\u{1b}"   // Esc cancels too

            let content = NSView()
            for v: NSView in [spinner, nameLabel, countLabel, cancel] {
                v.translatesAutoresizingMaskIntoConstraints = false
                content.addSubview(v)
            }
            NSLayoutConstraint.activate([
                content.widthAnchor.constraint(equalToConstant: 400),
                spinner.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                spinner.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                nameLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 10),
                nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
                nameLabel.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
                countLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
                countLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
                cancel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
                cancel.topAnchor.constraint(greaterThanOrEqualTo: countLabel.bottomAnchor, constant: 12),
                cancel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            ])
            panel.contentView = content
        }

        @objc private func cancelPressed() {
            // The blocked trigger thread is simply abandoned (it exits whenever its
            // read returns); the poll loop sees `finished` and stops rescheduling.
            finish(.cancelled)
        }

        // MARK: Per-file trigger + poll

        /// Kick off file `index`: update the labels, ask iCloud to download, fault the
        /// stub with a 1-byte read on a detached thread, and start polling. Past the
        /// last file → everything is local → finish(.ready).
        private func startFile(_ index: Int) {
            guard index < pending.count else { finish(.ready); return }
            currentIndex = index
            let url = pending[index]
            nameLabel.stringValue = "Downloading “\(url.lastPathComponent)”…"
            countLabel.stringValue = "file \(index + 1) of \(pending.count)"

            // iCloud items: ask the daemon to fetch (errors ignored — the generic
            // trigger below covers non-ubiquitous providers).
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)

            // Generic trigger: reading one byte faults the dataless stub, making the
            // File Provider materialize it. The read BLOCKS until the download lands,
            // so it runs on a DETACHED thread we abandon on cancel — never on main.
            let path = url.path
            let box = ErrorBox()
            Thread.detachNewThread {
                let fd = open(path, O_RDONLY)
                guard fd >= 0 else { box.error = CloudFile.posixError(errno); return }
                var byte: UInt8 = 0
                if read(fd, &byte, 1) < 0 { box.error = CloudFile.posixError(errno) }
                close(fd)
            }
            poll(url, index: index, box: box)
        }

        /// Poll every 300 ms: the placeholder check runs on a background queue (the
        /// resource-value probe can touch the provider daemon), then hops to main to
        /// advance / fail / reschedule. Materialized wins over a recorded read error —
        /// the bytes arrived, however messy the trigger was.
        private func poll(_ url: URL, index: Int, box: ErrorBox) {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.3) { [weak self] in
                let stillPlaceholder = CloudFile.isPlaceholder(url)
                let error = box.error
                // Bind strongly BEFORE the Task: the CI's older Swift rejects
                // `guard let self` on a weak capture inside concurrently-executing
                // code (same class of error as the PrinterManager timer fix).
                guard let session = self else { return }
                Task { @MainActor in
                    guard !session.finished else { return }
                    if !stillPlaceholder { session.startFile(index + 1) }
                    else if let error { session.finish(.failed(error)) }
                    else { session.poll(url, index: index, box: box) }
                }
            }
        }

        // MARK: Teardown

        private func finish(_ result: MaterializeResult) {
            guard !finished else { return }
            finished = true
            if let host = hostWindow, panel.sheetParent === host { host.endSheet(panel) }
            panel.orderOut(nil)
            // Surface a failure ONCE here (sheet-or-modal, with a "Report…" option),
            // so every call site keeps the one-line `guard case .ready` pattern.
            if case .failed(let error) = result {
                ErrorReporter.showErrorAlert(
                    title: "Couldn’t download “\(pending[currentIndex].lastPathComponent)”",
                    message: "The cloud provider couldn’t deliver the file: \(error.localizedDescription)",
                    details: "\(error)",
                    in: hostWindow,
                    appName: ErrorReporter.currentAppName())
            }
            completion(result)
            CloudFile.sessions.removeAll { $0 === self }
        }
    }
}
