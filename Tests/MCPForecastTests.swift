//
//  MCPForecastTests.swift
//  BurrowTests
//
//  End-to-end for the burrow_disk_forecast tool (roadmap A.3 agent surface):
//  seed real snapshot rows with a declining/flat disk and assert the tool's
//  JSON reply, exercising MetricsStore.diskFreeSeries → DiskForecast through
//  the actual dispatch path.
//

import XCTest
@testable import Burrow

final class MCPForecastTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-fc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// A snapshot with one "/" volume at `freeBytes` free of 500 GB.
    private func snapshot(freeBytes: Int64) -> String {
        let total: Int64 = 500_000_000_000
        let used = max(0, total - freeBytes)
        return """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin","uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":10,"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":100,"total":200,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},
         "disks":[{"mount":"/","used":\(used),"total":\(total),"used_percent":50,"external":false}],
         "top_processes":[]}
        """
    }

    private func obj(_ json: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    func testDiskForecast_steadyDecline_namesADate() throws {
        let now = Int(Date().timeIntervalSince1970)
        let day = 86_400
        for d in 0...30 {  // 31 daily points, -1 GB/day, ending ~100 GB free
            let free = Int64(130_000_000_000) - Int64(d) * 1_000_000_000
            try db.insert(prefix: MetricsStore.snapshotPrefix,
                          ts: now - (30 - d) * day, json: snapshot(freeBytes: free))
        }
        let json = try catalog.call(name: "burrow_disk_forecast", arguments: ["days": 60])
        let o = try obj(json)
        let daysUntil = try XCTUnwrap((o["days_until_full"] as? NSNumber)?.doubleValue, json)
        XCTAssertEqual(daysUntil, 100, accuracy: 15)
        let slope = try XCTUnwrap((o["slope_bytes_per_day"] as? NSNumber)?.doubleValue)
        XCTAssertLessThan(slope, 0)
    }

    func testDiskForecast_flatDisk_returnsNull() throws {
        let now = Int(Date().timeIntervalSince1970)
        let day = 86_400
        for d in 0...30 {
            try db.insert(prefix: MetricsStore.snapshotPrefix,
                          ts: now - (30 - d) * day, json: snapshot(freeBytes: 100_000_000_000))
        }
        let o = try obj(catalog.call(name: "burrow_disk_forecast", arguments: [:]))
        XCTAssertTrue(o["days_until_full"] is NSNull, "a flat disk never fills → null, not a bare date")
    }

    func testDiskForecast_isListedInCatalog() {
        let names = catalog.descriptors().compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains("burrow_disk_forecast"))
    }
}
