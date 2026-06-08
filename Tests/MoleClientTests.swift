//
//  MoleClientTests.swift
//  BurrowTests
//
//  The typed `mo` client turns each subcommand's output into typed values in
//  one place. The parsing is pure, so it's tested against captured output.
//

import XCTest
@testable import Burrow

final class MoleClientTests: XCTestCase {
    func testParseApps_decodesUninstallListJSON() {
        let json = """
        [{"name":"Slack","bundle_id":"com.tinyspeck.slackmacgap","source":"App","uninstall_name":"slack","path":"/Applications/Slack.app","size":"250MB"},
         {"name":"Zoom","path":"/Applications/zoom.us.app","size":"180MB"}]
        """.data(using: .utf8)!
        let apps = MoleClient.parseApps(json)
        XCTAssertEqual(apps.count, 2)
        XCTAssertEqual(apps[0].name, "Slack")
        XCTAssertEqual(apps[0].uninstallName, "slack")
        XCTAssertEqual(apps[0].bundleId, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(apps[0].sizeBytes, Int64(250 * 1_048_576))
        // Missing optional fields fall back.
        XCTAssertEqual(apps[1].source, "App")
        XCTAssertEqual(apps[1].uninstallName, "Zoom")   // falls back to the display name
    }

    func testParseApps_skipsRowsMissingRequiredFields() {
        // A row with no path can't be uninstalled — dropped.
        let json = #"[{"name":"NoPath"},{"name":"Good","path":"/Applications/Good.app"}]"#.data(using: .utf8)!
        XCTAssertEqual(MoleClient.parseApps(json).map(\.name), ["Good"])
    }

    func testParseApps_emptyOrMalformed_returnsEmpty() {
        XCTAssertTrue(MoleClient.parseApps(Data()).isEmpty)
        XCTAssertTrue(MoleClient.parseApps("not json".data(using: .utf8)!).isEmpty)
    }

    func testParseSize_handlesUnitsAndPlaceholders() {
        XCTAssertEqual(MoleClient.parseSize("1.5GB"), Int64(1.5 * 1_073_741_824))
        XCTAssertEqual(MoleClient.parseSize("250MB"), Int64(250 * 1_048_576))
        XCTAssertEqual(MoleClient.parseSize("--"), 0)
        XCTAssertEqual(MoleClient.parseSize(""), 0)
    }
}
