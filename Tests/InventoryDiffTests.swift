//
//  InventoryDiffTests.swift
//  BurrowTests
//
//  Set-membership diffing (roadmap B.8 / D.12), tested through `diff`.
//

import XCTest
@testable import Burrow

final class InventoryDiffTests: XCTestCase {
    func testDiff_addedAndRemoved() {
        let c = InventoryDiff.diff(old: ["a", "b", "c"], new: ["b", "c", "d"])
        XCTAssertEqual(c.added, ["d"])
        XCTAssertEqual(c.removed, ["a"])
        XCTAssertFalse(c.isEmpty)
    }

    func testDiff_outputIsSortedRegardlessOfInputOrder() {
        let c = InventoryDiff.diff(old: ["x"], new: ["zeta", "alpha", "x", "mu"])
        XCTAssertEqual(c.added, ["alpha", "mu", "zeta"], "added is sorted, stable")
        XCTAssertTrue(c.removed.isEmpty)
    }

    func testDiff_identicalInventories_isEmpty() {
        let c = InventoryDiff.diff(old: ["a", "b"], new: ["b", "a"])
        XCTAssertTrue(c.isEmpty, "same membership, different order → no change")
    }

    func testDiff_deduplicates() {
        let c = InventoryDiff.diff(old: ["a", "a"], new: ["a", "b", "b"])
        XCTAssertEqual(c.added, ["b"])
        XCTAssertTrue(c.removed.isEmpty)
    }

    func testDiff_emptyOldMeansAllNew() {
        let c = InventoryDiff.diff(old: [], new: ["a", "b"])
        XCTAssertEqual(c.added, ["a", "b"])
        XCTAssertTrue(c.removed.isEmpty)
    }
}
