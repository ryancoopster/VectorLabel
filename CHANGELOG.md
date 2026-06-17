# Changelog

All notable changes to VectorLabel. Versions are `MAJOR.MINOR.PATCH` (in `/VERSION`);
each build also carries a monotonic build number (git commit count) and short SHA,
shown in the menu-bar footer. Fix commits reference the code-review finding IDs
(H#, M#, L#) from the review report on the Desktop.

## [Unreleased]
### Fixed
- **[M7/M8/M9/M10]** Performance: visibleIndices is computed once per render (was
  ~12x); column detection is memoized by records identity; the print batch renders
  off the main thread (no UI freeze on large jobs); and inline-edit CSV writeback
  is debounced + written off-main. (H12 true row windowing deferred -- rows already
  use content-visibility for render virtualization; full DOM windowing is higher
  risk and needs UI testing.)
- **[H14/H15]** Treat imported templates as untrusted: both web views now sanitize
  template objects on import (regenerate ids, whitelist/strip the font, allow only
  data:image sources), closing the stored-XSS sinks where object fields were
  spliced into attributes/onclick/<img>. Added a restrictive Content-Security-
  Policy (img-src self/data:, object-src/connect-src none).
- **[H4/H5/H6/M1/M2/L1]** Formula engine now agrees across the designer preview,
  print preview, and Swift print renderer: Swift matches the JS comparison grammar
  (string equality after a bare identifier), JS truthiness ("0" is truthy),
  unknown-identifier fallback (shows the name), the friendly-name table, and
  JS-style number stringification. Unified the two JS FD tables. Pinned by golden
  tests including the real label templates.
- **[H7/M5/L3]** Moved blocking USB work off Swift's cooperative thread pool onto
  per-printer serial DispatchQueues (replacing the device semaphore), so long
  prints + pacing sleeps can no longer starve/deadlock the pool under multi-printer
  load. Added a scan-overlap guard. Clears the Swift-6 `wait` warnings.
- **[H3]** Pinned the CSV read/write round-trip: factored the RFC-4180 writer into
  WireExportParser.csvText and added a golden test proving an inline edit survives
  save->reload, including values with commas, quotes, and embedded newlines.
- **[H2]** Inline-edit CSV writeback can no longer corrupt the file: removed the
  sorted-union header fallback (it reordered/dropped columns) -- it now aborts if
  the source header can't be read -- and corrected the false "session-only"
  comment. (Read/write round-trip safety comes from the H1 parser.)
- **[H1]** Replaced the line-based CSV parser with a full-document RFC-4180
  parser: a newline inside a quoted field no longer tears the record (and drops
  every row after it, shifting absolute indices). Ragged rows are padded, never
  dropped, and logged. Covered by golden tests.
- **[L2]** Removed the temporary /tmp debug logs (SmartCell + print) that wrote
  unsynchronized from parallel per-printer tasks and dumped raw cassette bytes on
  every read.
- **[M13]** "Detect supply" now gives feedback: it reports failure ("Couldn't
  read the cassette�") and busy ("Printer busy�") instead of the toast silently
  fading, and a forced detect during a print is no longer silently dropped.
- **[M4]** Closed a filename -> JavaScript injection seam: dynamic strings spliced
  into evaluateJavaScript now route through one escaper that also handles CR/LF and
  U+2028/U+2029 (JS line terminators), so a crafted filename can no longer break
  out of the string literal. Guarded by a new test.
- **[H10]** Fixed a libusb context leak on every printer open (success and
  claim/open-failure paths) by using one shared, app-lifetime context instead of
  initializing/exiting one per call.
- **[H9]** A failed template save on edit-return no longer silently reverts the
  print window to the old template -- it now alerts and keeps the designer open
  so the edit is not lost.
- **[H8b]** A failed print now posts a system notification banner ("Print
  failed -- <job>, <printer>") so the operator is alerted even after the print
  window has closed. Notification permission is requested lazily, only on the
  first failure.
- **[H8]** USB print failures are no longer recorded as a successful "Complete"
  print -- added a `.failed` job/recent-print status (shown in red in the menu)
  set when a send throws mid-batch.
- **[H13]** Print window no longer rebuilt its entire DOM every 5s on idle — the
  USB scan now publishes the printer/cassette lists only when they actually
  change, eliminating the idle CPU/battery drain and scroll/focus disruption.
- **[H11]** Calibration grid printed at the wrong size for BM-109-427 cassettes —
  `calibrationSize` used a local part-number normalizer that omitted the
  bulk-box↔cartridge equivalence; now uses the canonical `BradyCatalog.core`.

### Added
- Build versioning: every build is stamped with semver + build number + commit SHA
  (`scripts/stamp-version.sh` → `BuildInfo`), shown in the menu-bar footer.
- Test target (`swift test`) with first regression guards (Brady part-number
  equivalences, labels-per-roll).
- GitHub Actions CI: build + test on every push/PR.
- Release pipeline scaffolding: `.app` packaging with bundled libusb, Developer ID
  signing, and notarization (`scripts/package-app.sh`, `.github/workflows/release.yml`,
  `docs/SIGNING.md`).

## [1.0.0] — baseline
- Pre-review baseline (tagged `v1.0-baseline`). Functional app: Vectorworks CSV →
  print window, template designer, Brady USB printing, recent prints, presets.
