//
//  TaskTickerTests.swift
//  BurrowTests
//
//  The Optimize live ticker (design 2.5) parses the streamed `mo
//  optimize` output into discrete completions: every marker line is a
//  finished task, the latest ➤ header is what the engine is working
//  through now. Totals are never guessed — the engine doesn't announce
//  one, so the count renders without a denominator.
//

import XCTest
@testable import Burrow

final class TaskTickerTests: XCTestCase {
    func testReduce_collectsCompletionsInOrder() {
        let state = TaskTicker.reduce([
            "➤ Periodic Maintenance",
            "  ✓ Periodic maintenance done",
            "➤ Launch Services",
            "  → Rebuild Launch Services database",
            "  ✓ Login items all healthy (3 checked)",
        ])
        XCTAssertEqual(state.completed.map(\.text),
                       ["Periodic maintenance done",
                        "Rebuild Launch Services database",
                        "Login items all healthy (3 checked)"])
        XCTAssertEqual(state.currentCategory, "Launch Services")
        XCTAssertEqual(state.count, 3)
    }

    func testReduce_ignoresNoiseAndSummary() {
        let state = TaskTicker.reduce([
            "",
            "  ↳ Path: ~/Library/Caches",
            "Potential space: 1.2GB | Items: 3 | Categories: 2",
            "═════════",
            "➤ Disk Health",
            "  ✓ SMART status verified",
        ])
        XCTAssertEqual(state.completed.map(\.text), ["SMART status verified"])
        XCTAssertEqual(state.currentCategory, "Disk Health")
    }

    func testReduce_emptyStreamHasNoCurrent() {
        let state = TaskTicker.reduce([])
        XCTAssertEqual(state.completed.count, 0)
        XCTAssertNil(state.currentCategory)
    }

    /// Error lines still count as completions (the engine moved on) but
    /// carry their marker so the ticker can color them.
    func testReduce_keepsMarkers() {
        let state = TaskTicker.reduce([
            "➤ Network",
            "  ✗ DNS cache flush failed",
        ])
        XCTAssertEqual(state.completed.first?.marker, .error)
    }
}
