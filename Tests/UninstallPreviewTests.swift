//
//  UninstallPreviewTests.swift
//  BurrowTests
//
//  `mo uninstall --dry-run <app>` enumerates every path the engine
//  would remove. The expandable leftover review (design 2.2) parses
//  that enumeration and classifies each path by shape: Application /
//  App Support / Preferences / containers / helpers / login items are
//  auto-selected; caches, logs, group containers and anything ambiguous
//  land in "Needs review", unchecked. Fixture captured from mole 1.41
//  (2026-06-11); parsing fails soft to the classic whole-app flow.
//

import XCTest
@testable import Burrow

final class UninstallPreviewTests: XCTestCase {
    /// Real transcript shape (ANSI stripped), Maccy on this machine.
    static let fixture = """
    → DRY RUN MODE, No app files or settings will be modified

    ◎ Matched 1 app(s):
    1. Maccy  7.4MB  |  Last: 6d ago

    Proceed with uninstallation? [y/N]\u{0020}
    Files to be removed:

    ◎ Maccy , 239.6MB
      ✓ /Applications/Maccy.app
      ✓ ~/Library/Containers/org.p0deje.Maccy
      ✓ ~/Library/Application Scripts/org.p0deje.Maccy
      ✓ ~/Library/Preferences/org.p0deje.Maccy.plist
      ✓ ~/Library/Caches/org.p0deje.Maccy

    ➤ Remove 1 app, 239.6MB [Running]  Enter confirm, ESC cancel:\u{0020}

    ======================================================================
    Uninstall dry run complete
    Would remove 1 app, would free 239.6MB: Maccy
    ======================================================================
    """

    func testParse_readsAppTotalAndPaths() {
        let preview = UninstallPreview.parse(Self.fixture.components(separatedBy: "\n"))
        XCTAssertEqual(preview.appName, "Maccy")
        XCTAssertEqual(preview.totalText, "239.6MB")
        XCTAssertEqual(preview.entries.count, 5)
        XCTAssertEqual(preview.entries.first?.path, "/Applications/Maccy.app")
    }

    func testParse_garbageFailsSoftToEmpty() {
        let preview = UninstallPreview.parse(["no enumeration here"])
        XCTAssertTrue(preview.entries.isEmpty)
        XCTAssertNil(preview.appName)
    }

    func testClassify_byPathShape() {
        XCTAssertEqual(UninstallPreview.classify("/Applications/Maccy.app"), .application)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Application Support/Maccy"), .appSupport)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Preferences/org.p0deje.Maccy.plist"), .preferences)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Containers/org.p0deje.Maccy"), .container)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Group Containers/group.com.x"), .groupContainer)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Application Scripts/org.p0deje.Maccy"), .helper)
        XCTAssertEqual(UninstallPreview.classify("~/Library/LaunchAgents/com.x.plist"), .loginItem)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Caches/org.p0deje.Maccy"), .cache)
        XCTAssertEqual(UninstallPreview.classify("/private/var/folders/ab/x/T/com.x"), .cache)
        XCTAssertEqual(UninstallPreview.classify("~/Library/Logs/Maccy"), .log)
        XCTAssertEqual(UninstallPreview.classify("/opt/weird/location"), .other)
    }

    /// Auto vs Needs review: removal essentials auto-tick; caches, logs,
    /// group containers and unknowns wait for a human.
    func testAutoSelection_split() {
        let auto: [UninstallPreview.Kind] = [.application, .appSupport, .preferences,
                                             .container, .helper, .loginItem]
        let review: [UninstallPreview.Kind] = [.cache, .log, .groupContainer, .other]
        for kind in auto { XCTAssertTrue(kind.autoSelected, "\(kind) should auto-select") }
        for kind in review { XCTAssertFalse(kind.autoSelected, "\(kind) should need review") }
    }

    func testParse_assignsKindsToEntries() {
        let preview = UninstallPreview.parse(Self.fixture.components(separatedBy: "\n"))
        XCTAssertEqual(preview.entries.map(\.kind),
                       [.application, .container, .helper, .preferences, .cache])
        let auto = preview.entries.filter(\.kind.autoSelected)
        XCTAssertEqual(auto.count, 4, "the cache row needs review")
    }
}
