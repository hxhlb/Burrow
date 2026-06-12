//
//  MoleWhitelistTests.swift
//  BurrowTests
//
//  The whitelist is Mole's protection mechanism: a plain glob file at
//  ~/.config/mole/whitelist, one pattern per line; `mo clean` skips
//  matches. Burrow builds two features on it:
//
//    * Settings ▸ Maintenance ▸ Protected Items — list/add/remove the
//      user's permanent patterns.
//    * Clean review (1.4) — a *session* of temporary exclusions wrapped
//      in a fenced block, appended before the real run and removed
//      after (plus a startup sweep for crash leftovers). The session
//      must never disturb the user's own entries.
//
//  All file ops run against a scratch temp file here — never the real
//  ~/.config/mole/whitelist.
//

import XCTest
@testable import Burrow

final class MoleWhitelistTests: XCTestCase {
    var dir: URL!
    var wl: MoleWhitelist!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("burrow-wl-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        wl = MoleWhitelist(fileURL: dir.appendingPathComponent("whitelist"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Reading & editing the user's permanent patterns

    func testPatterns_missingFileReadsEmpty() {
        XCTAssertEqual(wl.patterns(), [])
    }

    func testAdd_createsFileAndAppends() throws {
        try wl.add("/Users/*/Library/Caches/com.example.app")
        XCTAssertEqual(wl.patterns(), ["/Users/*/Library/Caches/com.example.app"])
    }

    func testAdd_isIdempotent() throws {
        try wl.add("~/.npm/_cacache")
        try wl.add("~/.npm/_cacache")
        XCTAssertEqual(wl.patterns(), ["~/.npm/_cacache"])
    }

    func testRemove_dropsOnlyThatPattern() throws {
        try wl.add("~/.npm/_cacache")
        try wl.add("~/Library/Caches/Homebrew")
        try wl.remove("~/.npm/_cacache")
        XCTAssertEqual(wl.patterns(), ["~/Library/Caches/Homebrew"])
    }

    func testPatterns_skipsCommentsAndBlanks() throws {
        let raw = "# a comment\n\n~/.cache/uv\n   \n# another\n"
        try raw.write(to: wl.fileURL, atomically: true, encoding: .utf8)
        XCTAssertEqual(wl.patterns(), ["~/.cache/uv"])
    }

    // MARK: - Session block (Clean review's temporary exclusions)

    func testBeginSession_appendsFencedBlock_andPatternsHidesIt() throws {
        try wl.add("~/.cache/keep-me")
        try wl.beginSession(excluding: ["/Users/x/Library/Caches/locked-app"])
        // The session paths are excluded from cleaning…
        let onDisk = try String(contentsOf: wl.fileURL, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("/Users/x/Library/Caches/locked-app"))
        XCTAssertTrue(onDisk.contains(MoleWhitelist.sessionBegin))
        // …but the user-facing Protected Items list shows only their own.
        XCTAssertEqual(wl.patterns(), ["~/.cache/keep-me"])
    }

    func testEndSession_restoresUserEntriesExactly() throws {
        try wl.add("~/.cache/keep-me")
        let before = try String(contentsOf: wl.fileURL, encoding: .utf8)
        try wl.beginSession(excluding: ["/tmp/a", "/tmp/b"])
        try wl.endSession()
        let after = try String(contentsOf: wl.fileURL, encoding: .utf8)
        XCTAssertEqual(after, before)
    }

    func testEndSession_withNoSessionIsANoOp() throws {
        try wl.add("~/.cache/keep-me")
        try wl.endSession()
        XCTAssertEqual(wl.patterns(), ["~/.cache/keep-me"])
    }

    /// Crash safety: a stale block from a previous run (even several) is
    /// swept; user entries around and between them survive.
    func testStripSessionBlock_removesEveryStaleBlock() {
        let content = """
        ~/.cache/keep-me
        \(MoleWhitelist.sessionBegin)
        /tmp/stale-1
        \(MoleWhitelist.sessionEnd)
        ~/Library/Caches/also-keep
        \(MoleWhitelist.sessionBegin)
        /tmp/stale-2
        \(MoleWhitelist.sessionEnd)
        """
        let swept = MoleWhitelist.stripSessionBlock(content)
        XCTAssertTrue(swept.contains("~/.cache/keep-me"))
        XCTAssertTrue(swept.contains("~/Library/Caches/also-keep"))
        XCTAssertFalse(swept.contains("stale-1"))
        XCTAssertFalse(swept.contains("stale-2"))
        XCTAssertFalse(swept.contains(MoleWhitelist.sessionBegin))
    }

    /// A begin fence whose end fence never made it to disk (crash mid-write)
    /// must still be swept — everything from the orphan fence on goes.
    func testStripSessionBlock_handlesUnterminatedBlock() {
        let content = "~/.cache/keep-me\n\(MoleWhitelist.sessionBegin)\n/tmp/orphan\n"
        let swept = MoleWhitelist.stripSessionBlock(content)
        XCTAssertTrue(swept.contains("~/.cache/keep-me"))
        XCTAssertFalse(swept.contains("/tmp/orphan"))
    }

    // MARK: - Glob safety: a session path must match exactly ITSELF

    /// mo reads whitelist lines as glob patterns. A literal path with
    /// metacharacters written verbatim would NOT match itself — the
    /// un-ticked item would be cleaned anyway, the exact fail-dangerous
    /// case the review screen exists to prevent.
    func testBeginSession_globEscapesLiteralPaths() throws {
        let tricky = "/Users/me/Library/Caches/app [1]/data*"
        try wl.beginSession(excluding: [tricky])
        let raw = try String(contentsOf: wl.fileURL, encoding: .utf8)
        XCTAssertTrue(raw.contains(#"/Users/me/Library/Caches/app \[1\]/data\*"#),
                      "metachars must be escaped so the pattern matches the literal path")
        XCTAssertFalse(raw.contains("\n" + tricky + "\n"),
                       "the unescaped path must not be written")
        // The sweep still removes the escaped block cleanly.
        try wl.endSession()
        XCTAssertEqual(wl.patterns(), [])
    }

    func testGlobEscaped_escapesEveryMetachar() {
        XCTAssertEqual(MoleWhitelist.globEscaped(#"a*b?c[d]e\f"#), #"a\*b\?c\[d\]e\\f"#)
        XCTAssertEqual(MoleWhitelist.globEscaped("/plain/path"), "/plain/path")
    }

    func testBeginSession_rejectsPathsThatBreakTheFileStructure() throws {
        try wl.add("~/.npm/_cacache")
        let before = try String(contentsOf: wl.fileURL, encoding: .utf8)

        // A newline would split into two lines — one garbage pattern, one
        // unprotected remainder. A path matching the fence text would
        // corrupt sweep parsing. Both must abort, leaving the file alone.
        XCTAssertThrowsError(try wl.beginSession(excluding: ["/tmp/a\nb"]))
        XCTAssertThrowsError(try wl.beginSession(excluding: [MoleWhitelist.sessionBegin]))
        XCTAssertEqual(try String(contentsOf: wl.fileURL, encoding: .utf8), before,
                       "an aborted session must not touch the file")
    }

    // MARK: - Unreadable file: abort, never wipe

    /// `?? ""` on an exists-but-unreadable file would make the next write
    /// destroy the user's curated patterns. Read failures must abort.
    func testBeginSession_unreadableFileAborts() throws {
        try wl.add("~/.npm/_cacache")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: wl.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: wl.fileURL.path) }

        XCTAssertThrowsError(try wl.beginSession(excluding: ["/tmp/x"]))

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: wl.fileURL.path)
        XCTAssertEqual(wl.patterns(), ["~/.npm/_cacache"],
                       "the user's patterns must survive an unreadable-file abort")
    }

    func testAdd_unreadableFileAborts() throws {
        try wl.add("~/.npm/_cacache")
        try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                              ofItemAtPath: wl.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                                       ofItemAtPath: wl.fileURL.path) }

        XCTAssertThrowsError(try wl.add("~/Library/Caches/Homebrew"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644],
                                              ofItemAtPath: wl.fileURL.path)
        XCTAssertEqual(wl.patterns(), ["~/.npm/_cacache"])
    }
}

final class SettingsStoreKeysTests: XCTestCase {
    static let scratchSuite = "dev.caezium.BurrowTests.scratch"

    override func setUp() {
        Store.d = UserDefaults(suiteName: Self.scratchSuite)!
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
    }

    override func tearDown() {
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
        Store.d = .standard
    }

    func testSkipIntro_defaultsFalseAndPersists() {
        XCTAssertFalse(Store.skipIntro)
        Store.skipIntro = true
        XCTAssertTrue(Store.skipIntro)
    }

    /// Permanent is the engine's truthful default (freed bytes are real);
    /// unknown junk in the key must clamp back to it.
    func testCacheRemovalMode_defaultsPermanentAndClampsUnknown() {
        XCTAssertEqual(Store.cacheRemovalMode, .permanent)
        Store.cacheRemovalMode = .trash
        XCTAssertEqual(Store.cacheRemovalMode, .trash)
        Store.d.set("garbage", forKey: "cache_removal_mode")
        XCTAssertEqual(Store.cacheRemovalMode, .permanent)
    }

    func testMenuBarDisplayMode_defaultsIconAndClampsUnknown() {
        XCTAssertEqual(Store.menuBarDisplayMode, .icon)
        Store.menuBarDisplayMode = .metrics
        XCTAssertEqual(Store.menuBarDisplayMode, .metrics)
        Store.d.set("mascot", forKey: "menu_bar_display_mode")
        XCTAssertEqual(Store.menuBarDisplayMode, .icon)
    }

    /// Global open-Burrow shortcut: none recorded by default; a recorded
    /// key roundtrips; clearing restores none.
    func testGlobalShortcut_defaultsNilRoundtripsAndClears() {
        XCTAssertNil(Store.globalShortcut)
        Store.globalShortcut = HotKey(keyCode: 46, modifiers: [.control, .option, .command]) // ^⌥⌘M
        XCTAssertEqual(Store.globalShortcut, HotKey(keyCode: 46, modifiers: [.control, .option, .command]))
        Store.globalShortcut = nil
        XCTAssertNil(Store.globalShortcut)
    }
}
