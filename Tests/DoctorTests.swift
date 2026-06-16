//
//  DoctorTests.swift
//  BurrowTests
//
//  The diagnostics verdict composer (roadmap I), tested through `report`.
//

import XCTest
@testable import Burrow

final class DoctorTests: XCTestCase {
    private func healthy() -> Doctor.Input {
        .init(fullDiskAccess: true, moInstalled: true, pressure: .normal,
              diskFreeBytes: 200_000_000_000, diskTotalBytes: 500_000_000_000,
              recentErrorCount: 0, lastBackupDaysAgo: 1)
    }

    private func check(_ report: [Doctor.Check], _ name: String) -> Doctor.Check? {
        report.first { $0.name == name }
    }

    func testReport_healthyMachine_allOK() {
        let r = Doctor.report(healthy())
        XCTAssertEqual(r.count, 6)
        XCTAssertTrue(r.allSatisfy { $0.level == .ok })
    }

    func testReport_staleBackup_warns() {
        var i = healthy(); i.lastBackupDaysAgo = 26
        XCTAssertEqual(check(Doctor.report(i), "Backups")?.level, .warn)
    }

    func testReport_noBackup_warns() {
        var i = healthy(); i.lastBackupDaysAgo = nil
        XCTAssertEqual(check(Doctor.report(i), "Backups")?.level, .warn)
    }

    func testReport_noEngine_fails() {
        var i = healthy(); i.moInstalled = false
        XCTAssertEqual(check(Doctor.report(i), "Engine")?.level, .fail)
    }

    func testReport_noFullDiskAccess_warns() {
        var i = healthy(); i.fullDiskAccess = false
        XCTAssertEqual(check(Doctor.report(i), "Full Disk Access")?.level, .warn)
    }

    func testReport_criticalPressure_fails() {
        var i = healthy(); i.pressure = .critical
        XCTAssertEqual(check(Doctor.report(i), "Memory pressure")?.level, .fail)
    }

    func testReport_diskNearlyFull_fails() {
        var i = healthy()
        i.diskFreeBytes = 10_000_000_000  // 2% of 500 GB
        XCTAssertEqual(check(Doctor.report(i), "Disk space")?.level, .fail)
    }

    func testReport_diskTight_warns() {
        var i = healthy()
        i.diskFreeBytes = 40_000_000_000  // 8% of 500 GB
        XCTAssertEqual(check(Doctor.report(i), "Disk space")?.level, .warn)
    }

    func testReport_recentErrors_warn() {
        var i = healthy(); i.recentErrorCount = 3
        let c = check(Doctor.report(i), "Recent errors")
        XCTAssertEqual(c?.level, .warn)
        XCTAssertTrue(c?.detail.contains("3") ?? false)
    }

    func testReport_sortableWorstFirst() {
        var i = healthy(); i.moInstalled = false; i.pressure = .critical
        let worst = Doctor.report(i).max { $0.level.rawValue < $1.level.rawValue }
        XCTAssertEqual(worst?.level, .fail, "Level.rawValue orders ok<warn<fail for sorting")
    }
}
