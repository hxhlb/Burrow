//
//  TreemapTests.swift
//  BurrowTests
//
//  Covers the squarified-treemap layout. The algorithm has a few
//  invariants worth pinning so future "perf improvements" can't quietly
//  break them:
//
//    * Total covered area equals the input bounds' area (to within
//      floating-point noise).
//    * No rectangle leaks outside the input bounds.
//    * Larger weights produce larger output rectangles (monotonic).
//    * The order of returned rectangles matches the order of the input
//      weights — callers index into a parallel array of entries.
//

import XCTest
@testable import Burrow

final class TreemapTests: XCTestCase {
    private let bounds = CGRect(x: 0, y: 0, width: 1000, height: 600)

    func testLayout_emptyWeightsReturnsEmpty() {
        XCTAssertTrue(Treemap.layout(weights: [], in: bounds).isEmpty)
    }

    func testLayout_singleWeightFillsBounds() {
        let rects = Treemap.layout(weights: [42], in: bounds)
        XCTAssertEqual(rects.count, 1)
        let r = rects[0]
        XCTAssertEqual(r.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(r.height, bounds.height, accuracy: 0.001)
    }

    func testLayout_zeroBoundsReturnsZeroRects() {
        let zeroBounds = CGRect(x: 0, y: 0, width: 0, height: 100)
        let rects = Treemap.layout(weights: [10, 20, 30], in: zeroBounds)
        XCTAssertEqual(rects.count, 3)
        for r in rects { XCTAssertEqual(r, .zero) }
    }

    func testLayout_allZeroWeightsReturnsZeroRects() {
        let rects = Treemap.layout(weights: [0, 0, 0], in: bounds)
        XCTAssertEqual(rects.count, 3)
        for r in rects { XCTAssertEqual(r, .zero) }
    }

    /// The sum of all returned areas must equal the bounds' area. This
    /// is the strongest single invariant — if it holds, we're not
    /// dropping data or double-counting.
    func testLayout_totalAreaEqualsBoundsArea() {
        let weights: [Double] = [600, 400, 200, 100, 50, 30, 20, 10, 5, 5]
        let rects = Treemap.layout(weights: weights, in: bounds)
        let totalArea = rects.reduce(0.0) { $0 + Double($1.width * $1.height) }
        let boundsArea = Double(bounds.width * bounds.height)
        XCTAssertEqual(totalArea, boundsArea, accuracy: 0.5,
                       "treemap should tile the bounds exactly")
    }

    /// No rect should poke out of the bounds. Catches off-by-one bugs in
    /// the row-finalization trim.
    func testLayout_noRectExceedsBounds() {
        let weights: [Double] = (1...20).map { Double($0 * $0) }
        let rects = Treemap.layout(weights: weights, in: bounds)
        for r in rects {
            XCTAssertGreaterThanOrEqual(r.minX, bounds.minX - 0.001)
            XCTAssertGreaterThanOrEqual(r.minY, bounds.minY - 0.001)
            XCTAssertLessThanOrEqual(r.maxX, bounds.maxX + 0.001)
            XCTAssertLessThanOrEqual(r.maxY, bounds.maxY + 0.001)
        }
    }

    /// Bigger inputs map to bigger output rects. Doesn't require exact
    /// area parity (different rows can give the same weight different
    /// thicknesses) — just that ranks line up.
    func testLayout_weightOrderRoughlyMatchesAreaOrder() {
        // Use widely separated weights so row-thickness variation can't
        // flip neighbouring ranks.
        let weights: [Double] = [1000, 100, 10, 1]
        let rects = Treemap.layout(weights: weights, in: bounds)
        let areas = rects.map { Double($0.width * $0.height) }
        XCTAssertGreaterThan(areas[0], areas[1])
        XCTAssertGreaterThan(areas[1], areas[2])
        XCTAssertGreaterThan(areas[2], areas[3])
    }

    /// Output order must match input order: the view code below us
    /// zips weights and entries by index.
    func testLayout_preservesInputOrder() {
        // Out-of-order weights to make sure we didn't accidentally sort
        // and forget to invert the permutation.
        let weights: [Double] = [50, 500, 25, 100]
        let rects = Treemap.layout(weights: weights, in: bounds)
        XCTAssertEqual(rects.count, weights.count)
        // Index 1 has the largest weight; it should have the largest area.
        let areas = rects.map { Double($0.width * $0.height) }
        XCTAssertEqual(areas.firstIndex(of: areas.max()!), 1,
                       "the biggest weight (index 1) should get the biggest rect")
    }

    /// Repeated calls with the same input return identical output —
    /// no hidden randomness.
    func testLayout_isDeterministic() {
        let weights: [Double] = [200, 150, 100, 80, 40, 20, 10]
        let a = Treemap.layout(weights: weights, in: bounds)
        let b = Treemap.layout(weights: weights, in: bounds)
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x, y)
        }
    }
}
