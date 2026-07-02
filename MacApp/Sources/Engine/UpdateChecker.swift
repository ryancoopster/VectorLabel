import AppKit
import Foundation
import VectorLabelCore
import VectorLabelUI

// MARK: – Available update (cached in AppSettings.updateAvailableJSON)

/// One release found on GitHub that is (or was) newer than the running build.
/// Cached as JSON in AppSettings so the Preferences "Updates" tab can show the
/// summary card — even for a skipped/snoozed version — without re-checking.
struct AvailableUpdate: Codable, Equatable, Sendable {
    var version: String        // "1.2.0" (tag_name with the leading "v" stripped)
    var tagName: String        // "v1.2.0"
    var notes: String          // release body (markdown; plain-textified for display)
    var pkgURLString: String   // browser_download_url of the installer .pkg ("" if none)
    var htmlURLString: String  // the release's web page (fallback when no .pkg asset)
}

// MARK: – GitHub releases-list wire format

/// The subset of GitHub's `GET /repos/…/releases` response we consume. Top-level
/// (not nested in UpdateChecker) so its Decodable conformance stays nonisolated.
private struct GitHubRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }
    let tagName: String
    let draft: Bool
    let prerelease: Bool      // our releases are all prereleases — accepted, never filtered
    let body: String?
    let htmlURL: String?
    let assets: [Asset]?
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case draft
        case prerelease
        case body
        case htmlURL = "html_url"
        case assets
    }
}

// MARK: – UpdateChecker

/// Checks GitHub releases for a newer VectorLabel, prompts the user, and runs the
/// download-and-install handoff. Lives in the Engine (the suite's long-running
/// process); policy + state persist in AppSettings (the Engine's UserDefaults).
///
/// All UI is app-modal NSAlert/NSPanel on the main actor. The pure decision logic
/// (semver compare, prompt gating, asset matching, release picking, markdown
/// plain-texting) is `nonisolated static` so UpdateCheckerTests exercises it
/// without networking or UI.
@MainActor
final class UpdateChecker: NSObject {

    static let shared = UpdateChecker()
    private override init() {}

    /// NOTE: /releases/latest is a 404 for this repo (every release is a
    /// prerelease, which "latest" excludes) — list and pick the max semver instead.
    private static let releasesURLString =
        "https://api.github.com/repos/ryancoopster/VectorLabel/releases?per_page=15"
    /// UserDefaults key for the releases-list ETag. Re-sending it as If-None-Match
    /// turns an unchanged list into a 304 that does NOT count against GitHub's
    /// 60/hour unauthenticated rate limit.
    private static let etagDefaultsKey = "updateReleasesETag"

    /// One check in flight at a time (the first-run "launch" choice and
    /// maybeAutoCheck can both fire during the same launch — the second is a no-op).
    private var isChecking = false
    private var downloadTask: URLSessionDownloadTask?
    private var downloadPanel: NSPanel?
    /// First-run prompt accessory controls, retained only while the prompt is up.
    private var firstRunRadios: [NSButton] = []
    private var firstRunDaysField: NSTextField?

    // MARK: – Pure logic (nonisolated static; unit-tested in UpdateCheckerTests)

    /// "v1.2.0" / "1.2" → [1,2,0] / [1,2]. nil for anything non-numeric — a
    /// malformed version is never treated as newer.
    nonisolated static func semverParts(_ version: String) -> [Int]? {
        var s = version.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        guard !s.isEmpty else { return nil }
        var parts: [Int] = []
        for segment in s.split(separator: ".", omittingEmptySubsequences: false) {
            guard let n = Int(segment), n >= 0 else { return nil }
            parts.append(n)
        }
        return parts
    }

    /// Numeric dot-segment compare (so 1.10.0 > 1.9.9); missing segments are 0
    /// (1.1 == 1.1.0). Malformed candidate → false; malformed current → any
    /// well-formed candidate wins.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let cand = semverParts(candidate) else { return false }
        let cur = semverParts(current) ?? []
        for i in 0..<max(cand.count, cur.count) {
            let a = i < cand.count ? cand[i] : 0
            let b = i < cur.count ? cur[i] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// The gate for the update-available popup. A user-initiated check always
    /// prompts; an automatic one respects the "Don't Update" pin and the
    /// "Remind Me Tomorrow" snooze (both Unix timestamps/strings from AppSettings,
    /// 0 / "" = unset).
    nonisolated static func shouldPrompt(userInitiated: Bool, version: String,
                                         skippedVersion: String, remindAfter: Double,
                                         now: Double) -> Bool {
        if userInitiated { return true }
        if version == skippedVersion { return false }
        return remindAfter == 0 || now >= remindAfter
    }

    /// True for the shipping installer asset ("VectorLabel-Installer-1.2.0.pkg").
    /// The digit after "Installer-" keeps the retired "-Beta-" variant out.
    nonisolated static func isInstallerAsset(_ name: String) -> Bool {
        name.range(of: #"^VectorLabel-Installer-[0-9][^/]*\.pkg$"#,
                   options: .regularExpression) != nil
    }

    /// Decode a GitHub releases-list response and pick the max-semver, non-draft
    /// release (prereleases included — that's all this repo publishes). Returns
    /// nil when no release has a parseable tag; throws only on malformed JSON.
    nonisolated static func bestAvailableRelease(inReleasesJSON data: Data) throws -> AvailableUpdate? {
        let releases = try JSONDecoder().decode([GitHubRelease].self, from: data)
        var best: AvailableUpdate?
        for release in releases where !release.draft {
            guard semverParts(release.tagName) != nil else { continue }  // unparseable tag → skip
            var version = release.tagName
            if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
            if let b = best, !isNewer(version, than: b.version) { continue }
            let pkg = (release.assets ?? []).first { isInstallerAsset($0.name) }
            best = AvailableUpdate(version: version,
                                   tagName: release.tagName,
                                   notes: release.body ?? "",
                                   pkgURLString: pkg?.browserDownloadURL ?? "",
                                   htmlURLString: release.htmlURL ?? "")
        }
        return best
    }

    /// Release notes arrive as markdown; the alert shows plain text. Strip the
    /// common noise: links → their text, heading #s, list bullets → "•",
    /// emphasis asterisks and backticks.
    nonisolated static func plainTextNotes(_ markdown: String) -> String {
        var text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
                                         options: .regularExpression)   // [text](url) → text
        text = text.replacingOccurrences(of: #"(?m)^#{1,6}\s*"#, with: "",
                                         options: .regularExpression)   // headings
        text = text.replacingOccurrences(of: #"(?m)^(\s*)[\*\-]\s+"#, with: "$1• ",
                                         options: .regularExpression)   // list bullets
        text = text.replacingOccurrences(of: "**", with: "")
        text = text.replacingOccurrences(of: "*", with: "")
        text = text.replacingOccurrences(of: "`", with: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AvailableUpdate ⇄ the AppSettings.updateAvailableJSON cache string.
    nonisolated static func decodeAvailableUpdate(_ json: String) -> AvailableUpdate? {
        guard !json.isEmpty, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AvailableUpdate.self, from: data)
    }
    nonisolated static func encodeAvailableUpdate(_ update: AvailableUpdate) -> String {
        guard let data = try? JSONEncoder().encode(update),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    // MARK: – Launch-time policy

    /// Run the persisted policy on Engine launch: "launch" always checks,
    /// "interval" checks when the last completed check is old enough (or never
    /// happened), "manual"/unset never auto-checks.
    func maybeAutoCheck() {
        let settings = AppSettings.shared
        switch settings.updatePolicy {
        case "launch":
            checkNow(userInitiated: false)
        case "interval":
            let last = settings.updateLastCheckTimestamp
            let interval = Double(max(1, settings.updateIntervalDays)) * 86_400
            if last == 0 || Date().timeIntervalSince1970 - last >= interval {
                checkNow(userInitiated: false)
            }
        default:
            break   // "manual" or "" (first-run prompt not answered) — never auto-check
        }
    }

    // MARK: – Check

    /// Hit the GitHub releases API (background URLSession; callbacks hop to main).
    /// Newer release found → cache it + maybe prompt. Nothing newer → clear the
    /// cache; user-initiated shows a small "up to date" alert. Errors are silent
    /// for automatic checks, an alert for user-initiated ones.
    func checkNow(userInitiated: Bool) {
        guard !isChecking else { return }
        isChecking = true
        guard let url = URL(string: Self.releasesURLString) else { isChecking = false; return }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests without a User-Agent.
        request.setValue("VectorLabel/\(BuildInfo.version)", forHTTPHeaderField: "User-Agent")
        // Manual ETag revalidation (a 304 is free w.r.t. the rate limit); bypass
        // URLCache so we actually SEE the 304 instead of a replayed 200.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let etag = UserDefaults.standard.string(forKey: Self.etagDefaultsKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            // URLSession calls back on its own queue; extract the (Sendable) pieces
            // and hop to the main actor. No mutable captures.
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            let etag = http?.value(forHTTPHeaderField: "ETag")
            Task { @MainActor in
                UpdateChecker.shared.handleCheckResponse(data: data, status: status, etag: etag,
                                                         error: error, userInitiated: userInitiated)
            }
        }
        task.resume()
    }

    private func handleCheckResponse(data: Data?, status: Int, etag: String?,
                                     error: (any Error)?, userInitiated: Bool) {
        isChecking = false
        let settings = AppSettings.shared
        if let error {
            if userInitiated {
                presentErrorAlert("Couldn’t check for updates", message: error.localizedDescription)
            }
            return
        }
        let now = Date().timeIntervalSince1970

        // 304 Not Modified: the release list hasn't changed since the ETagged
        // response — the cached find (or cached "nothing newer") still stands.
        if status == 304 {
            settings.updateLastCheckTimestamp = now
            if let cached = Self.decodeAvailableUpdate(settings.updateAvailableJSON),
               Self.isNewer(cached.version, than: BuildInfo.version) {
                maybePresentUpdatePrompt(cached, userInitiated: userInitiated)
            } else {
                settings.updateAvailableJSON = ""   // e.g. stale cache after the user updated
                if userInitiated { presentUpToDateAlert() }
            }
            return
        }
        guard status == 200, let data else {
            if userInitiated {
                presentErrorAlert("Couldn’t check for updates", message: "GitHub returned HTTP \(status).")
            }
            return
        }

        settings.updateLastCheckTimestamp = now
        if let etag, !etag.isEmpty { UserDefaults.standard.set(etag, forKey: Self.etagDefaultsKey) }
        let best: AvailableUpdate?
        do {
            best = try Self.bestAvailableRelease(inReleasesJSON: data)
        } catch {
            if userInitiated {
                presentErrorAlert("Couldn’t check for updates",
                                  message: "GitHub returned an unexpected response.")
            }
            return
        }
        if let best, Self.isNewer(best.version, than: BuildInfo.version) {
            settings.updateAvailableJSON = Self.encodeAvailableUpdate(best)
            maybePresentUpdatePrompt(best, userInitiated: userInitiated)
        } else {
            settings.updateAvailableJSON = ""
            if userInitiated { presentUpToDateAlert() }
        }
    }

    // MARK: – Update-available prompt

    private func maybePresentUpdatePrompt(_ update: AvailableUpdate, userInitiated: Bool) {
        let settings = AppSettings.shared
        guard Self.shouldPrompt(userInitiated: userInitiated, version: update.version,
                                skippedVersion: settings.updateSkippedVersion,
                                remindAfter: settings.updateRemindAfterTimestamp,
                                now: Date().timeIntervalSince1970) else { return }
        presentUpdatePrompt(update)
    }

    private func presentUpdatePrompt(_ update: AvailableUpdate) {
        // The Engine runs as an .accessory app — without activating first the
        // app-modal alert opens BEHIND whatever app is frontmost.
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "VectorLabel \(update.version) is available"
        alert.informativeText = "You have \(BuildInfo.version)."
        alert.accessoryView = Self.notesAccessory(update.notes)
        alert.addButton(withTitle: "Update Now")
        alert.addButton(withTitle: "Remind Me Tomorrow")
        alert.addButton(withTitle: "Don’t Update")
        let settings = AppSettings.shared
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            beginUpdate(update)
        case .alertSecondButtonReturn:
            settings.updateRemindAfterTimestamp = Date().timeIntervalSince1970 + 24 * 3600
        default:
            // "Don't Update" pins THIS version only (a newer release prompts
            // again) and clears any pending snooze.
            settings.updateSkippedVersion = update.version
            settings.updateRemindAfterTimestamp = 0
        }
    }

    /// Scrollable read-only release notes for the alert (markdown plain-textified).
    private static func notesAccessory(_ markdown: String) -> NSScrollView {
        let text = plainTextNotes(markdown)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 440, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.string = text.isEmpty ? "No release notes." : text
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        return scroll
    }

    // MARK: – Download + install handoff

    /// Download the installer .pkg (progress panel with Cancel) into ~/Downloads,
    /// open it, then take the suite down so the installer can replace every app.
    /// Also the entry point for the Preferences summary card's Update Now button.
    func beginUpdate(_ update: AvailableUpdate) {
        guard downloadTask == nil else { return }   // one download at a time
        guard let pkgURL = URL(string: update.pkgURLString), !update.pkgURLString.isEmpty else {
            // Release has no installer asset — send the user to the release page.
            if let page = URL(string: update.htmlURLString) { NSWorkspace.shared.open(page) }
            return
        }
        let fileName = pkgURL.lastPathComponent.isEmpty
            ? "VectorLabel-Installer-\(update.version).pkg" : pkgURL.lastPathComponent
        let task = URLSession.shared.downloadTask(with: pkgURL) { tempURL, _, error in
            // Move the file NOW, on this background queue — URLSession deletes the
            // temp file the moment this handler returns. `moved` is assigned exactly
            // once (no mutable captures cross the concurrency boundary).
            let moved: Result<URL, any Error>
            if let error {
                moved = .failure(error)
            } else if let tempURL {
                do { moved = .success(try Self.moveToDownloads(tempURL, preferredName: fileName)) }
                catch { moved = .failure(error) }
            } else {
                moved = .failure(URLError(.badServerResponse))
            }
            Task { @MainActor in UpdateChecker.shared.finishDownload(moved) }
        }
        showDownloadPanel(version: update.version, progress: task.progress)
        downloadTask = task
        task.resume()
    }

    /// Move the downloaded temp file into ~/Downloads, uniquing the name
    /// ("…-2.pkg", "…-3.pkg") if a previous download is already there.
    nonisolated private static func moveToDownloads(_ temp: URL, preferredName: String) throws -> URL {
        let fm = FileManager.default
        let downloads = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: (NSHomeDirectory() as NSString).appendingPathComponent("Downloads"))
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let base = (preferredName as NSString).deletingPathExtension
        let ext = (preferredName as NSString).pathExtension
        var dest = downloads.appendingPathComponent(preferredName)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = downloads.appendingPathComponent(ext.isEmpty ? "\(base)-\(n)" : "\(base)-\(n).\(ext)")
            n += 1
        }
        try fm.moveItem(at: temp, to: dest)
        return dest
    }

    private func showDownloadPanel(version: String, progress: Progress) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Software Update"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 380, height: 96))
        let label = NSTextField(labelWithString: "Downloading VectorLabel \(version)…")
        label.frame = NSRect(x: 20, y: 64, width: 340, height: 18)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 42, width: 340, height: 16))
        bar.style = .bar
        // Bind to the task's Progress: determinate once Content-Length is known,
        // indeterminate (barber pole) until then — AppKit switches automatically.
        bar.observedProgress = progress
        bar.startAnimation(nil)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelDownload))
        cancel.frame = NSRect(x: 276, y: 8, width: 90, height: 28)
        content.addSubview(label)
        content.addSubview(bar)
        content.addSubview(cancel)
        panel.contentView = content
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        downloadPanel = panel
    }

    @objc private func cancelDownload() {
        // The download completion then fires with URLError.cancelled → silent no-op.
        downloadTask?.cancel()
        closeDownloadPanel()
    }

    private func closeDownloadPanel() {
        downloadPanel?.orderOut(nil)
        downloadPanel = nil
    }

    private func finishDownload(_ moved: Result<URL, any Error>) {
        downloadTask = nil
        closeDownloadPanel()
        switch moved {
        case .success(let pkg):
            // Hand off to Installer, then take the suite down so it can replace all
            // four apps cleanly. The designers already quit when the Engine dies,
            // but AutoPrint does NOT watch the Engine — terminate each explicitly.
            NSWorkspace.shared.open(pkg)
            Self.terminateSiblingApps()
            // Short delay so the sibling terminate() AppleEvents and the Installer
            // launch get off the ground before the Engine itself exits.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { NSApp.terminate(nil) }
        case .failure(let error):
            if (error as? URLError)?.code == .cancelled { return }   // user hit Cancel
            presentErrorAlert("Couldn’t download the update", message: error.localizedDescription)
        }
    }

    /// Politely quit the other three suite apps (bundle ids via the beta-aware
    /// launcher, matching how the Engine launches them).
    private static func terminateSiblingApps() {
        for target in [DesignerAppLauncher.Target.autoPrint, .template, .custom] {
            let bundleID = DesignerAppLauncher.bundleID(for: target)
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
                app.terminate()
            }
        }
    }

    // MARK: – First-run policy prompt

    /// Ask ONCE how updates should be checked (updatePolicy == "" means "never
    /// asked" — a factory reset re-arms it). Persists the choice, then runs
    /// `completion` — the caller passes maybeAutoCheck, so choosing "On every
    /// launch" (or "Every N days" with no prior check) checks immediately.
    func firstRunPromptIfNeeded(then completion: () -> Void) {
        let settings = AppSettings.shared
        guard settings.updatePolicy.isEmpty else { completion(); return }
        NSApp.activate(ignoringOtherApps: true)   // .accessory app — surface the modal
        let alert = NSAlert()
        alert.messageText = "How should VectorLabel check for updates?"
        alert.informativeText = "You can change this any time in Preferences ▸ Updates."
        alert.accessoryView = makeFirstRunAccessory()
        alert.addButton(withTitle: "Continue")
        _ = alert.runModal()
        let selected = firstRunRadios.firstIndex { $0.state == .on } ?? 0
        let typedDays = firstRunDaysField?.integerValue ?? 7
        settings.updateIntervalDays = typedDays > 0 ? typedDays : 7
        settings.updatePolicy = ["launch", "interval", "manual"][selected]
        firstRunRadios = []
        firstRunDaysField = nil
        completion()
    }

    /// Radio group: On every launch / Every [N] days / Manually only.
    private func makeFirstRunAccessory() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 88))
        let launch = NSButton(radioButtonWithTitle: "On every launch",
                              target: self, action: #selector(firstRunRadioChanged(_:)))
        launch.frame = NSRect(x: 0, y: 62, width: 300, height: 20)
        launch.state = .on
        let interval = NSButton(radioButtonWithTitle: "Every",
                                target: self, action: #selector(firstRunRadioChanged(_:)))
        interval.frame = NSRect(x: 0, y: 34, width: 62, height: 20)
        let days = NSTextField(string: "7")
        days.frame = NSRect(x: 64, y: 32, width: 40, height: 22)
        days.alignment = .center
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.minimum = 1
        formatter.maximum = 365
        days.formatter = formatter
        let daysLabel = NSTextField(labelWithString: "days")
        daysLabel.frame = NSRect(x: 110, y: 36, width: 60, height: 16)
        let manual = NSButton(radioButtonWithTitle: "Manually only",
                              target: self, action: #selector(firstRunRadioChanged(_:)))
        manual.frame = NSRect(x: 0, y: 6, width: 300, height: 20)
        for view in [launch, interval, days, daysLabel, manual] { container.addSubview(view) }
        firstRunRadios = [launch, interval, manual]
        firstRunDaysField = days
        return container
    }

    @objc private func firstRunRadioChanged(_ sender: NSButton) {
        // The "Every … days" row has non-radio siblings, so enforce the radio
        // group exclusivity ourselves rather than rely on AppKit's auto-grouping.
        for radio in firstRunRadios where radio !== sender { radio.state = .off }
        sender.state = .on
    }

    // MARK: – Small alerts

    private func presentUpToDateAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "You’re up to date"
        alert.informativeText = "VectorLabel \(BuildInfo.version) is the newest version available."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func presentErrorAlert(_ title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
