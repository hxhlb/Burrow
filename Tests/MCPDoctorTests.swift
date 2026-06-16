//
//  MCPDoctorTests.swift
//  BurrowTests
//
//  End-to-end for burrow_doctor (roadmap I agent surface): the snapshot-derived
//  verdicts (memory pressure, disk headroom) are deterministic from a seeded
//  row; engine/FDA checks depend on the runner environment, so they aren't
//  asserted here.
//

import XCTest
@testable import Burrow

final class MCPDoctorTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-doc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func snapshot(pressure: String, freeGB: Int64) -> String {
        let total: Int64 = 500_000_000_000
        let used = total - freeGB * 1_000_000_000
        return """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin","uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":10,"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":100,"total":200,"used_percent":50,"swap_used":0,"swap_total":0,"pressure":"\(pressure)"},
         "disk_io":{"read_rate":0,"write_rate":0},
         "disks":[{"mount":"/","used":\(used),"total":\(total),"used_percent":98,"external":false}],
         "top_processes":[]}
        """
    }

    private func levels(_ json: String) throws -> [String: String] {
        let o = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], json)
        let checks = try XCTUnwrap(o["checks"] as? [[String: Any]], json)
        var out: [String: String] = [:]
        for c in checks { if let n = c["name"] as? String, let l = c["level"] as? String { out[n] = l } }
        return out
    }

    func testDoctor_seededCriticalSnapshot_failsPressureAndDisk() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: Int(Date().timeIntervalSince1970),
                      json: snapshot(pressure: "critical", freeGB: 10))  // 10/500 = 2% free
        let l = try levels(catalog.call(name: "burrow_doctor", arguments: [:]))
        XCTAssertEqual(l["Memory pressure"], "fail")
        XCTAssertEqual(l["Disk space"], "fail")        // 2% < 5%
        XCTAssertEqual(l.count, 6, "all six checks present")
    }

    func testDoctor_healthySnapshot_pressureAndDiskOK() throws {
        try db.insert(prefix: MetricsStore.snapshotPrefix, ts: Int(Date().timeIntervalSince1970),
                      json: snapshot(pressure: "", freeGB: 250))  // 50% free
        let l = try levels(catalog.call(name: "burrow_doctor", arguments: [:]))
        XCTAssertEqual(l["Memory pressure"], "ok")
        XCTAssertEqual(l["Disk space"], "ok")
    }

    func testDoctor_isListedInCatalog() {
        XCTAssertTrue(catalog.descriptors().compactMap { $0["name"] as? String }.contains("burrow_doctor"))
    }
}
