//
//  CleanWatchTests.swift
//  BurrowTests
//
//  "Clean Watch" lifetime totals (design 3.5): aggregate `mo history`
//  sessions into total bytes cleaned · apps uninstalled · optimize
//  runs. Pure over parsed sessions — and the popover hides the footer
//  entirely when the engine has no history command (older moles),
//  rather than showing zeros that read as "you never cleaned".
//

import XCTest
@testable import Burrow

final class CleanWatchTests: XCTestCase {
    private func session(_ command: String, size: String = "", items: Int = 0) -> HistorySession {
        HistorySession(command: command, startedAt: "2026-06-01T10:00:00Z", endedAt: "2026-06-01T10:01:00Z",
                       items: items, size: size, operationCount: 1,
                       removed: 0, trashed: 0, skipped: 0, failed: 0)
    }

    func testTotals_sumAcrossSessions() {
        let totals = CleanWatch.totals(from: [
            session("clean", size: "2.93GB"),
            session("clean", size: "500MB"),
            session("purge", size: "1GB"),
            session("uninstall", items: 2),
            session("uninstall", items: 1),
            session("optimize"),
            session("optimize"),
            session("optimize"),
        ])
        XCTAssertEqual(totals.cleanedBytes,
                       CleanList.parseSize("2.93GB") + CleanList.parseSize("500MB") + CleanList.parseSize("1GB"))
        XCTAssertEqual(totals.uninstalledApps, 3)
        XCTAssertEqual(totals.optimizeRuns, 3)
    }

    func testTotals_emptyIsAllZero() {
        let totals = CleanWatch.totals(from: [])
        XCTAssertEqual(totals, CleanWatch.Totals(cleanedBytes: 0, uninstalledApps: 0, optimizeRuns: 0))
        XCTAssertTrue(totals.isEmpty)
    }

    // MARK: - Top drain (battery card)

    func testTopDrain_heaviestByAverageCPU() {
        let a = ProcessInfo(pid: 1, ppid: nil, name: "Chrome", command: "chrome", cpu: 80, memory: 5, memoryBytes: nil)
        let b = ProcessInfo(pid: 2, ppid: nil, name: "Xcode", command: "xcode", cpu: 30, memory: 9, memoryBytes: nil)
        let c = ProcessInfo(pid: 1, ppid: nil, name: "Chrome", command: "chrome", cpu: 40, memory: 5, memoryBytes: nil)
        let result = TopDrain.heaviest([[a, b], [c, b]])
        XCTAssertEqual(result?.name, "Chrome")  // (80+40)/2 = 60 beats Xcode's 30
        XCTAssertEqual(result?.avgCPU ?? 0, 60, accuracy: 0.01)
    }

    func testTopDrain_emptyIsNil() {
        XCTAssertNil(TopDrain.heaviest([]))
        XCTAssertNil(TopDrain.heaviest([[]]))
    }

    // MARK: - PWR column formatting

    func testEnergyText_formatsCumulativeMilliwattHours() {
        XCTAssertEqual(ProcessActions.energyText(nanojoules: nil), "—")
        XCTAssertEqual(ProcessActions.energyText(nanojoules: 0), "—")
        // 3.6e9 nJ = 1 mWh
        XCTAssertEqual(ProcessActions.energyText(nanojoules: 3_600_000_000), "1")
        XCTAssertEqual(ProcessActions.energyText(nanojoules: 90_000_000_000), "25")
        XCTAssertEqual(ProcessActions.energyText(nanojoules: 1_000_000_000), "<1")
    }
}
