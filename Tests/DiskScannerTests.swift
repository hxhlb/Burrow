//
//  DiskScannerTests.swift
//  BurrowTests
//

import XCTest
@testable import Burrow

final class DiskScannerTests: XCTestCase {
    func testHomeScanSkipsTopLevelLibraryOnly() {
        let home = "/Users/example"

        XCTAssertTrue(DiskScanner.shouldSkipInHomeScan("/Users/example/Library", homeDirectory: home))
        XCTAssertFalse(DiskScanner.shouldSkipInHomeScan("/Users/example/Documents", homeDirectory: home))
        XCTAssertFalse(DiskScanner.shouldSkipInHomeScan("/Users/example/Documents/Library", homeDirectory: home))
    }
}
