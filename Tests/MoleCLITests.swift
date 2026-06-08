//
//  MoleCLITests.swift
//  BurrowTests
//
//  parseVersion is the only pure piece of the Mole-engine lifecycle
//  (install/version/update); the rest spawns `mo`. It must pull a semver
//  out of whatever `mo --version` decorates it with.
//

import XCTest
@testable import Burrow

final class MoleCLITests: XCTestCase {
    func testParseVersion_extractsSemverFromDecoratedOutput() {
        XCTAssertEqual(MoleCLI.parseVersion("mole 1.41.0"), "1.41.0")
        XCTAssertEqual(MoleCLI.parseVersion("v1.41.0\n"), "1.41.0")
        XCTAssertEqual(MoleCLI.parseVersion("mole version 2.0.10 (build 7)"), "2.0.10")
    }

    func testParseVersion_nilWhenNoVersion() {
        XCTAssertNil(MoleCLI.parseVersion("no version here"))
        XCTAssertNil(MoleCLI.parseVersion(""))
    }

    func testParseVersion_ignoresLoneNumbers() {
        // A bare integer isn't a version; needs at least major.minor.
        XCTAssertNil(MoleCLI.parseVersion("built for macOS 14"))
    }
}
