//
//  MoleHistoryTests.swift
//  BurrowTests
//
//  Pins the `mo history --json` parser against a real sample of Mole's
//  output shape.
//

import XCTest
@testable import Burrow

final class MoleHistoryTests: XCTestCase {
    private let sample = """
    {
      "logs": {"operations": "/x/operations.log"},
      "limit": 20,
      "sessions": [
        { "command": "clean", "started_at": "2026-06-06 20:33:49", "ended_at": "2026-06-06 20:35:23",
          "items": 118, "size": "2.93GB", "operation_count": 126,
          "actions": {"removed": 100, "trashed": 0, "skipped": 24, "failed": 2, "rebuilt": 0, "other": 0} },
        { "command": "optimize", "started_at": "2026-06-06 20:32:46", "ended_at": "",
          "items": 0, "size": "0B", "operation_count": 0,
          "actions": {"removed": 0, "trashed": 0, "skipped": 0, "failed": 0} }
      ]
    }
    """

    func testParse_mapsSessionsAndActions() {
        let sessions = MoleHistory.parse(Data(sample.utf8))
        XCTAssertEqual(sessions.count, 2)
        let clean = sessions[0]
        XCTAssertEqual(clean.command, "clean")
        XCTAssertEqual(clean.items, 118)
        XCTAssertEqual(clean.size, "2.93GB")
        XCTAssertEqual(clean.removed, 100)
        XCTAssertEqual(clean.skipped, 24)
        XCTAssertEqual(clean.failed, 2)
        XCTAssertTrue(clean.isComplete)
    }

    func testParse_emptyEndedAtMeansIncomplete() {
        let sessions = MoleHistory.parse(Data(sample.utf8))
        XCTAssertFalse(sessions[1].isComplete, "blank ended_at → session didn't finish")
    }

    func testParse_toleratesGarbage() {
        XCTAssertEqual(MoleHistory.parse(Data("not json".utf8)).count, 0)
        XCTAssertEqual(MoleHistory.parse(Data("{}".utf8)).count, 0)
    }
}
