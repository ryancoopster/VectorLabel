import XCTest
@testable import VectorLabelEngine

/// Pure-logic tests for the GitHub auto-updater (Engine/UpdateChecker.swift):
/// semver compare, prompt gating, installer-asset matching, releases-list
/// decoding, and the markdown → plain-text notes cleanup. No networking, no UI —
/// everything exercised here is a `nonisolated static` on UpdateChecker.
final class UpdateCheckerTests: XCTestCase {

    // MARK: – Semver compare

    func testSemverNewerBasics() {
        XCTAssertTrue(UpdateChecker.isNewer("1.2.0", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.0", than: "1.2.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.1.0", than: "1.1.0"))   // equal → not newer
    }

    func testSemverCompareIsNumericNotLexicographic() {
        // Lexicographic compare would say "1.10.0" < "1.9.9" — must be numeric.
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.9", than: "1.10.0"))
    }

    func testSemverStripsLeadingV() {
        XCTAssertTrue(UpdateChecker.isNewer("v1.2.0", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.1.0", than: "v1.1.0"))
    }

    func testSemverMissingSegmentsAreZero() {
        XCTAssertFalse(UpdateChecker.isNewer("1.1", than: "1.1.0"))     // 1.1 == 1.1.0
        XCTAssertTrue(UpdateChecker.isNewer("1.1.0.1", than: "1.1.0"))  // extra segment wins
        XCTAssertTrue(UpdateChecker.isNewer("2", than: "1.9.9"))
    }

    func testSemverMalformedIsNeverNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("banana", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.x", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("1.2.0-rc1", than: "1.1.0"))  // no prerelease grammar
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v", than: "1.1.0"))
    }

    // MARK: – Prompt gating

    func testPromptGatingTruthTable() {
        let now = 1_000_000.0
        // Clean state → prompt.
        XCTAssertTrue(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.2.0",
                                                 skippedVersion: "", remindAfter: 0, now: now))
        // "Don't Update" pinned THIS version → no auto prompt…
        XCTAssertFalse(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.2.0",
                                                  skippedVersion: "1.2.0", remindAfter: 0, now: now))
        // …but a DIFFERENT (newer) version prompts normally.
        XCTAssertTrue(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.3.0",
                                                 skippedVersion: "1.2.0", remindAfter: 0, now: now))
        // Snoozed into the future → no auto prompt.
        XCTAssertFalse(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.2.0",
                                                  skippedVersion: "", remindAfter: now + 60, now: now))
        // Snooze expired → prompt again.
        XCTAssertTrue(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.2.0",
                                                 skippedVersion: "", remindAfter: now - 60, now: now))
        // Snooze boundary: exactly at remindAfter counts as expired.
        XCTAssertTrue(UpdateChecker.shouldPrompt(userInitiated: false, version: "1.2.0",
                                                 skippedVersion: "", remindAfter: now, now: now))
        // User-initiated overrides BOTH the skip pin and the snooze.
        XCTAssertTrue(UpdateChecker.shouldPrompt(userInitiated: true, version: "1.2.0",
                                                 skippedVersion: "1.2.0", remindAfter: now + 60, now: now))
    }

    // MARK: – Installer asset matching

    func testInstallerAssetRegex() {
        XCTAssertTrue(UpdateChecker.isInstallerAsset("VectorLabel-Installer-1.2.0.pkg"))
        XCTAssertTrue(UpdateChecker.isInstallerAsset("VectorLabel-Installer-10.0.pkg"))
        // The retired beta variant must NOT match ("B" where a digit is required).
        XCTAssertFalse(UpdateChecker.isInstallerAsset("VectorLabel-Installer-Beta-1.2.0.pkg"))
        // Wrong container formats.
        XCTAssertFalse(UpdateChecker.isInstallerAsset("VectorLabel-Installer-1.2.0.zip"))
        XCTAssertFalse(UpdateChecker.isInstallerAsset("VectorLabel-Installer-1.2.0.dmg"))
        // Anchored: no prefix/suffix noise, no path separators.
        XCTAssertFalse(UpdateChecker.isInstallerAsset("x-VectorLabel-Installer-1.2.0.pkg"))
        XCTAssertFalse(UpdateChecker.isInstallerAsset("VectorLabel-Installer-1.2.0.pkg.sig"))
        XCTAssertFalse(UpdateChecker.isInstallerAsset("VectorLabel-Installer-1/evil.pkg"))
    }

    // MARK: – Releases-list decoding (canned GitHub response)

    /// Deliberately out of order, with a draft, an unparseable tag, and a beta
    /// asset ahead of the real installer — the picker must still land on v1.2.0.
    private static let releasesFixture = #"""
    [
      {
        "tag_name": "v1.1.0",
        "draft": false,
        "prerelease": true,
        "body": "Old release",
        "html_url": "https://github.com/ryancoopster/VectorLabel/releases/tag/v1.1.0",
        "assets": [
          {"name": "VectorLabel-Installer-1.1.0.pkg",
           "browser_download_url": "https://example.com/dl/VectorLabel-Installer-1.1.0.pkg"}
        ]
      },
      {
        "tag_name": "v1.3.0",
        "draft": true,
        "prerelease": true,
        "body": "Unpublished draft — must be ignored",
        "html_url": "https://github.com/ryancoopster/VectorLabel/releases/tag/v1.3.0",
        "assets": []
      },
      {
        "tag_name": "nightly-build",
        "draft": false,
        "prerelease": true,
        "body": "Unparseable tag — must be skipped",
        "html_url": "https://github.com/ryancoopster/VectorLabel/releases/tag/nightly-build",
        "assets": []
      },
      {
        "tag_name": "v1.2.0",
        "draft": false,
        "prerelease": true,
        "body": "# 1.2.0\n* Auto-update from GitHub releases\n* [Docs](https://example.com)",
        "html_url": "https://github.com/ryancoopster/VectorLabel/releases/tag/v1.2.0",
        "assets": [
          {"name": "VectorLabel-Installer-Beta-1.2.0.pkg",
           "browser_download_url": "https://example.com/dl/VectorLabel-Installer-Beta-1.2.0.pkg"},
          {"name": "VectorLabel-Installer-1.2.0.pkg",
           "browser_download_url": "https://example.com/dl/VectorLabel-Installer-1.2.0.pkg"}
        ]
      }
    ]
    """#

    func testBestReleasePicksMaxSemverNonDraft() throws {
        let update = try XCTUnwrap(
            try UpdateChecker.bestAvailableRelease(inReleasesJSON: Data(Self.releasesFixture.utf8)))
        XCTAssertEqual(update.version, "1.2.0")            // not the 1.3.0 draft, not 1.1.0
        XCTAssertEqual(update.tagName, "v1.2.0")
        XCTAssertEqual(update.pkgURLString,
                       "https://example.com/dl/VectorLabel-Installer-1.2.0.pkg")  // beta skipped
        XCTAssertEqual(update.htmlURLString,
                       "https://github.com/ryancoopster/VectorLabel/releases/tag/v1.2.0")
        XCTAssertTrue(update.notes.contains("Auto-update"))
    }

    func testBestReleaseEmptyListIsNil() throws {
        XCTAssertNil(try UpdateChecker.bestAvailableRelease(inReleasesJSON: Data("[]".utf8)))
    }

    func testBestReleaseMalformedJSONThrows() {
        XCTAssertThrowsError(
            try UpdateChecker.bestAvailableRelease(inReleasesJSON: Data("not json".utf8)))
    }

    // MARK: – Cache round-trip + notes plain-texting

    func testAvailableUpdateCacheRoundTrip() {
        let update = AvailableUpdate(version: "1.2.0", tagName: "v1.2.0", notes: "notes",
                                     pkgURLString: "https://example.com/a.pkg",
                                     htmlURLString: "https://example.com/rel")
        let json = UpdateChecker.encodeAvailableUpdate(update)
        XCTAssertFalse(json.isEmpty)
        XCTAssertEqual(UpdateChecker.decodeAvailableUpdate(json), update)
        XCTAssertNil(UpdateChecker.decodeAvailableUpdate(""))       // sentinel = no update
        XCTAssertNil(UpdateChecker.decodeAvailableUpdate("junk"))
    }

    func testPlainTextNotesStripsMarkdown() {
        let markdown = "# 1.2.0\n* **Bold** fix in `UpdateChecker`\n- See [the docs](https://example.com)"
        let plain = UpdateChecker.plainTextNotes(markdown)
        XCTAssertEqual(plain, "1.2.0\n• Bold fix in UpdateChecker\n• See the docs")
    }

    // MARK: – Changelog between-versions span (against the REAL CHANGELOG.md)

    /// The repo's actual CHANGELOG.md — the same file the release workflow cuts the
    /// release body from and the prompt fetches per tag. Parsing the real thing keeps
    /// the parser honest about the file's actual heading/footer conventions.
    private static func realChangelog() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MacApp/Tests/
            .deletingLastPathComponent()   // MacApp/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("CHANGELOG.md")
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testChangelogSectionsParseRealFile() throws {
        let sections = UpdateChecker.changelogSections(inChangelogMarkdown: try Self.realChangelog())
        // Newest-first, no "[Unreleased]", every released version present.
        let versions = sections.map(\.version)
        XCTAssertFalse(versions.contains("Unreleased"))
        XCTAssertEqual(Array(versions.suffix(6)),
                       ["1.4.1", "1.4.0", "1.3.1", "1.3.0", "1.2.0", "1.1.0"])
        for section in sections {
            XCTAssertNotNil(UpdateChecker.semverParts(section.version))
            XCTAssertFalse(section.date.isEmpty, "\(section.version) heading lost its date")
            XCTAssertFalse(section.body.isEmpty, "\(section.version) section came back empty")
        }
        // The link-reference footer must not leak into the last section's body.
        let oldest = try XCTUnwrap(sections.last)
        XCTAssertFalse(oldest.body.contains("]: https://github.com/ryancoopster/VectorLabel/"))
    }

    func testChangelogSpanBetweenInstalledAndOffered() throws {
        let changelog = try Self.realChangelog()
        // Installed 1.2.0, offered 1.4.1 → exactly 1.4.1 + 1.4.0 + 1.3.1 + 1.3.0,
        // newest first — NOT 1.2.0 itself, and nothing older.
        let span = try XCTUnwrap(UpdateChecker.composeNotesSpan(
            changelogMarkdown: changelog, installed: "1.2.0", offered: "1.4.1"))
        XCTAssertTrue(span.hasPrefix("What’s new since 1.2.0"))
        let headings = ["## 1.4.1", "## 1.4.0", "## 1.3.1", "## 1.3.0"]
        var lastIndex = span.startIndex
        for heading in headings {   // presence AND newest-first order
            let range = try XCTUnwrap(span.range(of: heading), "missing \(heading)")
            XCTAssertTrue(range.lowerBound >= lastIndex, "\(heading) out of order")
            lastIndex = range.lowerBound
        }
        XCTAssertFalse(span.contains("## 1.2.0"))
        XCTAssertFalse(span.contains("## 1.1.0"))
        // Body spot-checks: a 1.4.1 bullet is in, a 1.2.0 bullet is out.
        XCTAssertTrue(span.contains("No more duplicate tabs"))
        XCTAssertFalse(span.contains("Table object"))
    }

    func testChangelogSpanEqualVersionsIsEmpty() throws {
        // Same installed and offered version → no span → caller falls back.
        XCTAssertNil(UpdateChecker.composeNotesSpan(
            changelogMarkdown: try Self.realChangelog(), installed: "1.4.1", offered: "1.4.1"))
    }

    func testChangelogSpanUnknownInstalledKeepsEverythingUpToOffered() throws {
        // Malformed installed version → every section ≤ offered qualifies (isNewer
        // treats a malformed `current` as older than anything) — and the header
        // doesn't name the unparseable version.
        let span = try XCTUnwrap(UpdateChecker.composeNotesSpan(
            changelogMarkdown: try Self.realChangelog(), installed: "dev-build", offered: "1.3.1"))
        XCTAssertTrue(span.hasPrefix("What’s new:"))
        for heading in ["## 1.3.1", "## 1.3.0", "## 1.2.0", "## 1.1.0"] {
            XCTAssertTrue(span.contains(heading), "missing \(heading)")
        }
        XCTAssertFalse(span.contains("## 1.4.0"))   // newer than offered → excluded
        XCTAssertFalse(span.contains("## 1.4.1"))
    }

    func testChangelogSpanNoParseableSectionsIsNil() {
        XCTAssertNil(UpdateChecker.composeNotesSpan(
            changelogMarkdown: "# Changelog\n\n## [Unreleased]\n- pending\n",
            installed: "1.2.0", offered: "1.4.1"))
        XCTAssertNil(UpdateChecker.composeNotesSpan(
            changelogMarkdown: "not a changelog at all", installed: "1.2.0", offered: "1.4.1"))
    }
}
