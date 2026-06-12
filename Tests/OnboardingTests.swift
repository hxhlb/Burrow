//
//  OnboardingTests.swift
//  BurrowTests
//
//  First-run onboarding gate: shows exactly once on a fresh install
//  (after the mo-missing gate), never again once completed. The flag
//  lives in Store like every other persisted bit.
//

import XCTest
@testable import Burrow

final class OnboardingTests: XCTestCase {
    static let scratchSuite = "dev.caezium.BurrowTests.scratch"

    override func setUp() {
        Store.d = UserDefaults(suiteName: Self.scratchSuite)!
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
    }

    override func tearDown() {
        Store.d.removePersistentDomain(forName: Self.scratchSuite)
        Store.d = .standard
    }

    // Fresh install → onboarding not yet completed → the slides show.
    func testOnboardingCompleted_defaultsFalseAndPersists() {
        XCTAssertFalse(Store.onboardingCompleted)
        Store.onboardingCompleted = true
        XCTAssertTrue(Store.onboardingCompleted)
    }
}
