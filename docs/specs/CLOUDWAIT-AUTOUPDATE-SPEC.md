# Cloud-file download-wait + GitHub auto-update — spec

## Feature A: wait for online-only (cloud placeholder) files

Dropbox/iCloud/OneDrive "online-only" files are APFS **dataless placeholders**; reading
them blocks (or fails) until the provider materializes the data. Every place the app
consumes a user-chosen file must first ensure the file is local, showing a cancellable
"downloading" popup meanwhile.

### Core helper — `CloudFile` (new file MacApp/Sources/Core/CloudFile.swift)

```swift
public enum CloudFile {
    /// Dataless placeholder? Checks BOTH: stat st_flags & SF_DATALESS (File Provider —
    /// Dropbox/OneDrive/new iCloud) AND URLResourceValues
    /// .ubiquitousItemDownloadingStatusKey != .current (classic iCloud).
    public static func isPlaceholder(_ url: URL) -> Bool

    /// Ensure `urls` are fully local, then completion(.success) ON MAIN. If any are
    /// placeholders: show ONE small panel — "Downloading \"name\"…" (+ "file i of n"
    /// when n>1), indeterminate spinner, Cancel button — as a sheet on `window`
    /// (app-modal floating panel when window == nil). Cancel → completion(.cancelled),
    /// caller returns to its prior state (i.e. simply does nothing further).
    public static func materialize(_ urls: [URL], for window: NSWindow?,
                                   whenReady completion: @escaping (MaterializeResult) -> Void)
    public enum MaterializeResult { case ready, cancelled, failed(Error) }
}
```

Materialization mechanics (per file, background queue):
- iCloud items: `FileManager.default.startDownloadingUbiquitousItem(at:)` (ignore errors).
- Generic trigger: `open(path, O_RDONLY)` + `read` 1 byte on a **detached background
  thread** (the read blocks until the provider materializes — that IS the trigger;
  on cancel we abandon the thread, never block main).
- Completion detection: poll every 300 ms — done when `!isPlaceholder(url)`.
- No timeout (Cancel is the escape hatch). Errors from stat/read → .failed with an
  NSAlert at the call site per existing conventions.
- Fast path: if none of the urls are placeholders, call completion(.ready)
  synchronously — zero UI flash for the 99% local case.

### Hook EVERY file-consumption site (from the map; pattern):

```swift
CloudFile.materialize([url], for: window) { result in
    guard case .ready = result else { return }   // cancelled → back where you were
    …original open/import/read code…
}
```

Sites: all NSOpenPanel completions (CSV/XLSX data pickers in Print + Custom Designer,
template Open/Browse, image picker, .BWT/.lbx import), all four app delegates'
`application(_:open:)` handlers, all drag-and-drop file handlers. Save panels excluded.

## Feature B: auto-update from GitHub releases

### Data + policy (AppSettings — Engine's UserDefaults; survives updates)

- `updatePolicy: String` — "launch" | "manual" | "interval"
- `updateIntervalDays: Int` (default 7, min 1)
- `updateLastCheck: Date?`
- `updateSkippedVersion: String?` — "Don't update" pins THIS version; never prompt for
  it again; a NEWER version prompts normally (and clears the skip).
- `updateRemindAfter: Date?` — "Remind me tomorrow" = now + 24h; same version doesn't
  prompt before this (manual checks ignore it).
- `updateFirstRunDone: Bool`
- Cached last-found update (version, notes, pkg URL, html URL) for the Preferences
  summary: `updateAvailableJSON: String?`.

### Checker — `UpdateChecker` (new file MacApp/Sources/Engine/UpdateChecker.swift)

- `GET https://api.github.com/repos/ryancoopster/VectorLabel/releases?per_page=15`
  with `Accept: application/vnd.github+json` and a `User-Agent` (GitHub requires one).
  NOTE: our releases are PRERELEASES — `/releases/latest` excludes them; list and pick.
- Pick the max **semver** among non-draft releases (tag_name "vX.Y.Z" → strip v).
  Compare against the running version (BuildInfo / CFBundleShortVersionString).
- Asset: first asset whose name matches `^VectorLabel-Installer-.*\.pkg$`.
- Release notes: the release `body` (markdown) — display as plain text (strip #, *, `).
- `checkNow(userInitiated:)`: always allowed; updates lastCheck; on find, cache it.
  Prompt rules: prompt when newer AND (userInitiated OR (version != skippedVersion AND
  (remindAfter == nil || now >= remindAfter))).
- `maybeAutoCheck()` on Engine launch: policy "launch" → check; "interval" → check when
  lastCheck == nil || now - lastCheck >= intervalDays; "manual" → never.
- All network + JSON on background; UI on main. Failures: silent for auto checks,
  NSAlert for user-initiated ("Couldn't check for updates: …").

### UI (Engine)

1. **First-launch prompt** (once, `updateFirstRunDone`): small modal window/alert —
   "How should VectorLabel check for updates?" — radio: On every launch / Every [N]
   days (stepper or text field, default 7) / Manually only → saves policy. Runs before
   any auto check; choosing "On every launch" triggers an immediate check.
2. **Update-available popup**: app-modal alert/panel — title "VectorLabel X.Y.Z is
   available" (subtitle "You have Y.Z.W"), scrollable release notes, buttons:
   **Update Now** / **Remind Me Tomorrow** / **Don't Update**.
   - Update Now → download the .pkg (URLSession downloadTask; progress panel with
     Cancel) into ~/Downloads, then `NSWorkspace.shared.open(pkg)` and terminate the
     Engine (the suite follows it down, per existing engine-quit behavior) so the
     installer replaces the apps cleanly.
   - Remind Me Tomorrow → remindAfter = +24h.
   - Don't Update → skippedVersion = version; clear remindAfter.
3. **Preferences → new "Updates" section/tab**: policy control (popup: On launch /
   Every N days [field] / Manually) bound to AppSettings; "Check for Updates Now"
   button with a "Last checked: …" label; and when the cached available version is
   newer than running: a summary box — "Version X.Y.Z available" + first lines of the
   notes + **Update Now** button (shown even if the version was skipped or snoozed).

### Tests

Unit tests (FoundationTests or new UpdateTests): semver compare (1.1.0 < 1.2.0,
1.10.0 > 1.9.9, v-prefix, malformed → not newer), prompt-gating truth table (skipped /
remind-after / user-initiated), asset-name matching, release-list JSON decode from a
canned GitHub response fixture.

## Release plan (after implementation verifies)

Bump VERSION → 1.2.0; CHANGELOG: move [Unreleased] under [1.2.0] (+ these two
features); downloads.html: add 1.2.0 entry (direct pkg link) above 1.1.0; commit; tag
v1.2.0; CI publishes the signed pkg. User installs from GitHub. The NEXT release then
end-to-end-tests the auto-updater.
