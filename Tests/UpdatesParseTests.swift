//
//  UpdatesParseTests.swift
//  BurrowTests
//
//  The brew-outdated parser is the runner family's last untested parser; pin it
//  against captured `brew outdated --json=v2` output.
//

import XCTest
@testable import Burrow

final class UpdatesParseTests: XCTestCase {
    func testParseOutdated_readsFormulaeAndCasks() {
        let json = """
        {"formulae":[{"name":"git","installed_versions":["2.43.0"],"current_version":"2.44.0"}],
         "casks":[{"name":"slack","installed_versions":["4.0.0"],"current_version":"4.1.0"}]}
        """
        let items = UpdatesModel.parseOutdated(json)
        XCTAssertEqual(items.count, 2)
        let git = items.first { $0.name == "git" }
        XCTAssertEqual(git?.kind, "formula")
        XCTAssertEqual(git?.installed, "2.43.0")
        XCTAssertEqual(git?.latest, "2.44.0")
        XCTAssertEqual(items.first { $0.name == "slack" }?.kind, "cask")
    }

    func testParseOutdated_handlesMissingFieldsAndEmpty() {
        // No installed version → "?" placeholder; unnamed rows skipped.
        let json = #"{"formulae":[{"current_version":"1.0"},{"name":"wget"}],"casks":[]}"#
        let items = UpdatesModel.parseOutdated(json)
        XCTAssertEqual(items.map(\.name), ["wget"])
        XCTAssertEqual(items.first?.installed, "?")
        XCTAssertTrue(UpdatesModel.parseOutdated("not json").isEmpty)
        XCTAssertTrue(UpdatesModel.parseOutdated("").isEmpty)
    }
}
