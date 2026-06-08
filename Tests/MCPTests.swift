//
//  MCPTests.swift
//  BurrowTests
//
//  Smoke-tests the MCP tool catalog routing without standing up the
//  full stdio loop. The dispatcher (`MCPServer.handleLine`) is harder
//  to test directly because it owns FileHandles; calling
//  `ToolCatalog.call(...)` exercises the same code path one layer
//  below the JSON-RPC envelope and proves each tool name resolves +
//  returns valid JSON.
//

import XCTest
@testable import Burrow

final class MCPTests: XCTestCase {
    private var tempDir: URL!
    private var db: DB!
    private var catalog: ToolCatalog!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("burrow-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        db = try DB(at: tempDir.appendingPathComponent("burrow.db"))
        catalog = ToolCatalog(db: db)

        // Seed a couple of snapshots so tools have something to return.
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 60, json: sampleSnapshot(cpu: 22.5))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now,      json: sampleSnapshot(cpu: 88.0))
    }

    override func tearDown() {
        db = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDescriptors_listsAllToolsWithSchema() {
        let d = catalog.descriptors()
        let names = d.compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(names),
                       ["burrow_snapshot", "burrow_history", "burrow_top_processes",
                        "burrow_process_usage", "burrow_info"])
        // Every tool must carry an inputSchema and a description.
        for tool in d {
            XCTAssertNotNil(tool["description"] as? String)
            XCTAssertNotNil(tool["inputSchema"] as? [String: Any])
        }
    }

    func testCallSnapshot_returnsLatestRow() throws {
        let json = try catalog.call(name: "burrow_snapshot", arguments: [:])
        // Parses as a JSON object containing the snapshot.
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["ts"])
        XCTAssertNotNil(obj["snapshot"])
    }

    func testCallHistory_returnsRowCountAndRows() throws {
        let json = try catalog.call(name: "burrow_history", arguments: ["minutes": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let count = try XCTUnwrap(obj["count"] as? Int)
        XCTAssertGreaterThan(count, 0)
        let rows = try XCTUnwrap(obj["rows"] as? [[String: Any]])
        XCTAssertEqual(rows.count, count)
    }

    func testCallHistory_rejectsZeroMinutes() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_history", arguments: ["minutes": 0])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    func testCallTopProcesses_returnsAggregatedList() throws {
        let json = try catalog.call(name: "burrow_top_processes", arguments: ["minutes": 5, "limit": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["window_minutes"] as? Int, 5)
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        // Our seeded snapshots include a `top_processes` entry; the
        // aggregate should surface it.
        XCTAssertGreaterThan(procs.count, 0)
        let first = try XCTUnwrap(procs.first)
        XCTAssertNotNil(first["name"] as? String)
        XCTAssertNotNil(first["peak_cpu"] as? Double)
    }

    func testCallInfo_includesReadersAndRetention() throws {
        let json = try catalog.call(name: "burrow_info", arguments: [:])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNotNil(obj["now"])
        XCTAssertNotNil(obj["retention_days"])
        let readers = try XCTUnwrap(obj["readers"] as? [[String: Any]])
        XCTAssertEqual(readers.count, 1)
        XCTAssertEqual(readers[0]["prefix"] as? String, Sampler.snapshotPrefix)
    }

    /// The semantic usage tool must re-rank by the requested metric — the
    /// whole point of adding it over burrow_top_processes (which only ever
    /// ranks by peak CPU and so calls a one-second spike the "top" process).
    /// "heavy" runs hot the whole window; "spike" peaks once then idles.
    func testCallProcessUsage_ranksByChosenMetric() throws {
        // (setUp already seeded a `kernel_task` at ~110% cumulative; pick
        // timestamps off the seed rows so we don't collide on the PK and
        // make `heavy` out-rank it on cumulative load.)
        let now = Int(Date().timeIntervalSince1970)
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 300,
                      json: snapshotJSON([("heavy", 60, 5)]))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 240,
                      json: snapshotJSON([("heavy", 60, 5)]))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 180,
                      json: snapshotJSON([("heavy", 60, 5), ("spike", 1, 1)]))
        try db.insert(prefix: Sampler.snapshotPrefix, ts: now - 120,
                      json: snapshotJSON([("spike", 95, 1)]))

        let byCPUTime = try names(from: catalog.call(name: "burrow_process_usage",
                                                     arguments: ["minutes": 30, "metric": "cpu_time"]))
        XCTAssertEqual(byCPUTime.first, "heavy", "sustained load wins cumulative CPU-time")

        let byPeak = try names(from: catalog.call(name: "burrow_process_usage",
                                                  arguments: ["minutes": 30, "metric": "peak_cpu"]))
        XCTAssertEqual(byPeak.first, "spike", "the one-second spike wins peak CPU")
    }

    func testCallProcessUsage_reportsWindowItUsed() throws {
        let json = try catalog.call(name: "burrow_process_usage", arguments: ["minutes": 5])
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        // It must echo the window + metric so the agent isn't guessing.
        XCTAssertEqual(obj["window_minutes"] as? Int, 5)
        XCTAssertNotNil(obj["start_ts"]); XCTAssertNotNil(obj["end_ts"])
        XCTAssertNotNil(obj["sample_count"]); XCTAssertNotNil(obj["metric"])
    }

    func testCallProcessUsage_rejectsUnknownMetric() {
        XCTAssertThrowsError(try catalog.call(name: "burrow_process_usage",
                                              arguments: ["metric": "vibes"])) { err in
            guard case MCPToolError.badArguments = err else {
                return XCTFail("expected .badArguments, got \(err)")
            }
        }
    }

    // The `burrow mcp` PATH-shim invocation must be recognised alongside
    // the original `--mcp` flag, and ordinary launches must not be.
    func testIsMCPInvocation_recognisesFlagAndSubcommand() {
        XCTAssertTrue(BurrowMain.isMCPInvocation(["Burrow", "--mcp"]))
        XCTAssertTrue(BurrowMain.isMCPInvocation(["burrow", "mcp"]))
        XCTAssertFalse(BurrowMain.isMCPInvocation(["Burrow"]))
        XCTAssertFalse(BurrowMain.isMCPInvocation(["Burrow", "status"]))
    }

    func testCallUnknownTool_throwsUnknown() {
        XCTAssertThrowsError(try catalog.call(name: "no_such_tool", arguments: [:])) { err in
            guard case MCPToolError.unknown(let name) = err else {
                return XCTFail("expected .unknown, got \(err)")
            }
            XCTAssertEqual(name, "no_such_tool")
        }
    }

    // MARK: - Helpers

    /// Pull the ordered process names out of a burrow_process_usage result.
    private func names(from json: String) throws -> [String] {
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let procs = try XCTUnwrap(obj["processes"] as? [[String: Any]])
        return procs.compactMap { $0["name"] as? String }
    }

    /// A snapshot whose `top_processes` is the given (name, cpu%, mem%) list.
    private func snapshotJSON(_ procs: [(String, Double, Double)]) -> String {
        let entries = procs.enumerated().map { i, p in
            "{ \"pid\": \(i + 1), \"ppid\": 0, \"name\": \"\(p.0)\", \"command\": \"\(p.0)\", \"cpu\": \(p.1), \"memory\": \(p.2) }"
        }.joined(separator: ",")
        return """
        {
          "collected_at": "2026-05-31T12:00:00.000000-07:00",
          "host": "test", "platform": "darwin", "uptime": "1h 0m",
          "uptime_seconds": 3600, "procs": 100,
          "hardware": {
            "model": "Test", "cpu_model": "Test", "total_ram": "16GB",
            "disk_size": "512GB", "os_version": "14.5", "refresh_rate": "60Hz"
          },
          "health_score": 80, "health_score_msg": "ok",
          "cpu": { "usage": 10.0, "load1": 1.0, "load5": 1.0, "load15": 1.0, "core_count": 8, "logical_cpu": 8 },
          "memory": { "used": 1000, "total": 16000, "used_percent": 50.0, "swap_used": 0, "swap_total": 0, "pressure": "normal" },
          "disk_io": { "read_rate": 1.0, "write_rate": 2.0 },
          "top_processes": [\(entries)]
        }
        """
    }

    /// Minimal valid Mole snapshot JSON. Includes only what the
    /// callers we test actually decode (top_processes for the
    /// aggregation test, the rest are structurally required by the
    /// Codable struct).
    private func sampleSnapshot(cpu: Double) -> String {
        return """
        {
          "collected_at": "2026-05-31T12:00:00.000000-07:00",
          "host": "test",
          "platform": "darwin",
          "uptime": "1h 0m",
          "uptime_seconds": 3600,
          "procs": 100,
          "hardware": {
            "model": "Test", "cpu_model": "Test", "total_ram": "16GB",
            "disk_size": "512GB", "os_version": "14.5", "refresh_rate": "60Hz"
          },
          "health_score": 80,
          "health_score_msg": "ok",
          "cpu": {
            "usage": \(cpu), "load1": 1.0, "load5": 1.0, "load15": 1.0,
            "core_count": 8, "logical_cpu": 8
          },
          "memory": {
            "used": 1000, "total": 16000, "used_percent": 50.0,
            "swap_used": 0, "swap_total": 0, "pressure": "normal"
          },
          "disk_io": { "read_rate": 1.0, "write_rate": 2.0 },
          "top_processes": [
            { "pid": 1, "ppid": 0, "name": "kernel_task", "command": "kernel", "cpu": \(cpu), "memory": 10.0 }
          ]
        }
        """
    }
}
