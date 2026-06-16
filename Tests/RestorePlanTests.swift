//
//  RestorePlanTests.swift
//  BurrowTests
//
//  Restore planning (roadmap D.13), tested through `build` with an injected
//  filesystem probe.
//

import XCTest
@testable import Burrow

final class RestorePlanTests: XCTestCase {
    func testTrashedItem_noCollision_isRestorable() {
        let plan = RestorePlan.build([.init(originalPath: "/Users/x/App.app", action: "trash")],
                                     existsAtOriginal: { _ in false })
        XCTAssertEqual(plan.first?.restorable, true)
        XCTAssertEqual(RestorePlan.restorableCount(plan), 1)
    }

    func testPermanentlyRemovedItem_notRestorable() {
        let plan = RestorePlan.build([.init(originalPath: "/Users/x/cache", action: "remove")],
                                     existsAtOriginal: { _ in false })
        XCTAssertEqual(plan.first?.restorable, false)
        XCTAssertTrue(plan.first?.reason.contains("permanently") ?? false)
    }

    func testTrashedItem_originalPathTaken_isCollision() {
        let plan = RestorePlan.build([.init(originalPath: "/Users/x/App.app", action: "trash")],
                                     existsAtOriginal: { $0 == "/Users/x/App.app" })
        XCTAssertEqual(plan.first?.restorable, false)
        XCTAssertTrue(plan.first?.reason.contains("already exists") ?? false)
    }

    func testParseLog_extractsOkEntriesNewestFirst() {
        let log = """
        1700000000\ttrash\tcache\tok\t/Users/x/A.app
        1700000001\tremove\tlog\tok\t/Users/x/old.log
        1700000002\ttrash\tcache\tfailed\t/Users/x/B.app
        """
        let items = RestorePlan.parseLog(log)
        XCTAssertEqual(items.map(\.originalPath), ["/Users/x/old.log", "/Users/x/A.app"], "ok-only, newest first")
        XCTAssertEqual(items.first?.action, "remove")
    }

    func testParseLog_skipsMalformedLines() {
        XCTAssertTrue(RestorePlan.parseLog("garbage\nalso bad").isEmpty)
    }

    func testMixedSession_countsOnlyRestorable() {
        let plan = RestorePlan.build([
            .init(originalPath: "/a", action: "trash"),   // restorable
            .init(originalPath: "/b", action: "remove"),  // permanent
            .init(originalPath: "/c", action: "trash"),   // collision
        ], existsAtOriginal: { $0 == "/c" })
        XCTAssertEqual(RestorePlan.restorableCount(plan), 1)
    }
}
