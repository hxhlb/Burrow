//
//  UpdateCheckTests.swift
//  BurrowTests
//
//  Manual "Check for Updates": compare the running version against the
//  latest GitHub release. Comparison is numeric per component (0.6.10 >
//  0.6.9 — lexicographic would get this wrong) and tolerant of a leading
//  "v" on tags. Parsing pins to the two release fields we use.
//

import XCTest
@testable import Burrow

final class UpdateCheckTests: XCTestCase {
    func testIsNewer_numericPerComponent() {
        XCTAssertTrue(UpdateCheck.isNewer("0.7.0", than: "0.6.7"))
        XCTAssertTrue(UpdateCheck.isNewer("0.6.10", than: "0.6.9"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("0.6.7", than: "0.7.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0", than: "0.9.9"))   // shorter remote
        XCTAssertTrue(UpdateCheck.isNewer("0.6.7.1", than: "0.6.7")) // longer remote
    }

    func testIsNewer_toleratesLeadingV() {
        XCTAssertTrue(UpdateCheck.isNewer("v0.7.0", than: "0.6.7"))
        XCTAssertFalse(UpdateCheck.isNewer("v0.6.7", than: "v0.6.7"))
    }

    func testParseLatestRelease_readsTagAndURL() throws {
        let json = """
        {"tag_name": "v0.7.0", "html_url": "https://github.com/caezium/Burrow/releases/tag/v0.7.0",
         "name": "Burrow 0.7.0", "draft": false, "prerelease": false}
        """
        let release = try XCTUnwrap(UpdateCheck.parseLatestRelease(Data(json.utf8)))
        XCTAssertEqual(release.version, "0.7.0")
        XCTAssertEqual(release.url.absoluteString, "https://github.com/caezium/Burrow/releases/tag/v0.7.0")
    }

    func testParseLatestRelease_rejectsGarbage() {
        XCTAssertNil(UpdateCheck.parseLatestRelease(Data("not json".utf8)))
        XCTAssertNil(UpdateCheck.parseLatestRelease(Data("{}".utf8)))
    }
}
