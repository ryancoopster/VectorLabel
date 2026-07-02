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
}
