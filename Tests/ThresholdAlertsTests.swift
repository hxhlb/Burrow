//
//  ThresholdAlertsTests.swift
//  BurrowTests
//
//  Threshold-rule orchestration over snapshots (roadmap D.12).
//

import XCTest
@testable import Burrow

final class ThresholdAlertsTests: XCTestCase {
    private func status(cpu: Double, mem: Double) throws -> MoleStatus {
        let json = """
        {"collected_at":"2026-06-08T03:16:25.068057-07:00","host":"h","platform":"darwin","uptime_seconds":100,"procs":1,
         "hardware":{"model":"Mac","cpu_model":"M","total_ram":"24 GB","disk_size":"460 GB","os_version":"26"},
         "health_score":90,"health_score_msg":"Good",
         "cpu":{"usage":\(cpu),"load1":1,"load5":1,"load15":1,"core_count":10,"logical_cpu":10},
         "memory":{"used":100,"total":200,"used_percent":\(mem),"swap_used":0,"swap_total":0,"pressure":""},
         "disk_io":{"read_rate":0,"write_rate":0},"top_processes":[]}
        """
        return try JSONDecoder().decode(MoleStatus.self, from: Data(json.utf8))
    }

    func testReading_mapsRulesToMetrics() throws {
        let s = try status(cpu: 42, mem: 55)
        XCTAssertEqual(ThresholdAlerts.reading("cpu", in: s), 42)
        XCTAssertEqual(ThresholdAlerts.reading("memory", in: s), 55)
        XCTAssertNil(ThresholdAlerts.reading("bogus", in: s))
    }

    func testEvaluate_firesCPUWhenPegged_thenNotWhileStillPegged() throws {
        let hot = try status(cpu: 95, mem: 50)
        let r1 = ThresholdAlerts.evaluate(hot, ts: 0, states: [:])
        XCTAssertEqual(r1.fires.map(\.ruleID), ["cpu"])
        let r2 = ThresholdAlerts.evaluate(hot, ts: 60, states: r1.states)
        XCTAssertTrue(r2.fires.isEmpty, "one alert per episode, not per sample")
    }

    func testEvaluate_quietSnapshot_noFires() throws {
        let calm = try status(cpu: 20, mem: 40)
        XCTAssertTrue(ThresholdAlerts.evaluate(calm, ts: 0, states: [:]).fires.isEmpty)
    }

    func testEvaluate_bothHigh_firesBoth() throws {
        let bad = try status(cpu: 96, mem: 94)
        XCTAssertEqual(Set(ThresholdAlerts.evaluate(bad, ts: 0, states: [:]).fires.map(\.ruleID)),
                       ["cpu", "memory"])
    }
}
