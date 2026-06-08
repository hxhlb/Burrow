//
//  SnapshotStoreTests.swift
//  BurrowTests
//
//  Boundary tests for the typed snapshot reader, against a temporary database
//  (the local-substitutable way — real SQLite, no mocks), mirroring DBTests.
//

import XCTest
@testable import Burrow

final class SnapshotStoreTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-snap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Minimal valid `mo status --json` with a given CPU usage.
    private func snapshotJSON(cpu: Double) -> String {
        """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin",
         "uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":\(cpu),"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":1,"total":2,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0}}
        """
    }

    func testRange_decodesStoredSnapshotsInWindow() throws {
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))

        let snaps = SnapshotStore.range(db, since: 0, until: 1000, maxPoints: 100)
        XCTAssertEqual(snaps.map(\.ts), [100, 200])
        XCTAssertEqual(snaps.map { Int($0.status.cpu.usage) }, [10, 80])
    }

    func testRange_excludesRowsOutsideWindow() throws {
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 5000, json: snapshotJSON(cpu: 80))
        let snaps = SnapshotStore.range(db, since: 0, until: 1000, maxPoints: 100)
        XCTAssertEqual(snaps.map(\.ts), [100])
    }

    func testRange_skipsMalformedRows() throws {
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 100, json: "not valid json")
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 50))
        let snaps = SnapshotStore.range(db, since: 0, until: 1000, maxPoints: 100)
        XCTAssertEqual(snaps.count, 1)
        XCTAssertEqual(Int(snaps[0].status.cpu.usage), 50)
    }

    func testLatest_returnsMostRecentDecoded() throws {
        XCTAssertNil(SnapshotStore.latest(db), "empty store → nil")
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 100, json: snapshotJSON(cpu: 10))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: 200, json: snapshotJSON(cpu: 80))
        XCTAssertEqual(Int(SnapshotStore.latest(db)?.status.cpu.usage ?? -1), 80)
    }
}
