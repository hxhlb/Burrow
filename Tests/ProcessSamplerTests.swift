//
//  ProcessSamplerTests.swift
//  BurrowTests
//
//  The `ps` parser behind the Status process table. Pure function of the
//  output text — pinned here so a format assumption (field order, padding,
//  paths with spaces) can't silently drop rows.
//

import XCTest
@testable import Burrow

final class ProcessSamplerTests: XCTestCase {
    func testParseTypicalRows() throws {
        // Real `ps axo pid=,ppid=,pcpu=,pmem=,rss=,comm=` output is
        // right-aligned with space padding; comm is last because it can
        // contain spaces.
        let out = """
            1     0   0.1  0.2    9632 /sbin/launchd
          501     1  12.5  3.4  524288 /Applications/Visual Studio Code.app/Contents/MacOS/Electron
          734     1   0.0  0.1    2048 /usr/libexec/secd
        """
        let rows = ProcessSampler.parse(out)
        XCTAssertEqual(rows.count, 3)

        // Sorted by CPU descending.
        XCTAssertEqual(rows.first?.pid, 501)
        XCTAssertEqual(rows.first?.ppid, 1)
        XCTAssertEqual(rows.first?.cpu, 12.5)
        XCTAssertEqual(rows.first?.memory, 3.4)

        // comm keeps its spaces; name is the executable's last component.
        XCTAssertEqual(rows.first?.command,
                       "/Applications/Visual Studio Code.app/Contents/MacOS/Electron")
        XCTAssertEqual(rows.first?.name, "Electron")

        // rss arrives in KiB → bytes.
        XCTAssertEqual(rows.first?.memoryBytes, 524_288 * 1024)
        XCTAssertEqual(rows.last?.pid, 734)
    }

    func testMalformedLinesAreSkippedNeverInvented() {
        let out = """
          90 1 1.0 0.5 100 /usr/bin/good
          not a process line
          91 1 nonsense 0.5 100 /usr/bin/badcpu
          92 1 1.0
        """
        let rows = ProcessSampler.parse(out)
        XCTAssertEqual(rows.map(\.pid), [90], "only the well-formed row survives")
    }

    func testZeroRSSMeansNoMemoryBytes() throws {
        // Kernel rows report rss 0 — the UI falls back to percent, so the
        // parser must say "unknown" (nil), never "0 bytes".
        let rows = ProcessSampler.parse("  0  0  0.0  0.0  0 kernel_task\n")
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(try XCTUnwrap(rows.first).memoryBytes)
        XCTAssertEqual(rows.first?.name, "kernel_task")
    }

    func testEmptyOutputParsesToNoRows() {
        XCTAssertTrue(ProcessSampler.parse("").isEmpty)
        XCTAssertTrue(ProcessSampler.parse("\n\n").isEmpty)
    }

    func testPsArgsKeepCommLastAndHeaderless() {
        // `=` suppresses the header row; comm MUST stay the final column —
        // it's the only field that may contain spaces, and the parser
        // treats everything after the fifth split as the command.
        XCTAssertEqual(ProcessSampler.psArgs, ["axo", "pid=,ppid=,pcpu=,pmem=,rss=,comm="])
    }

    /// One live smoke pass: `/bin/ps` exists on every macOS box, so the
    /// sampler should return a non-empty, CPU-sorted list that includes
    /// this very test process.
    func testSampleAgainstRealPS() {
        let rows = ProcessSampler.sample()
        XCTAssertGreaterThan(rows.count, 5, "a real Mac runs more than five processes")
        XCTAssertTrue(rows.contains { $0.pid == Int(getpid()) }, "we are in the list")
        let cpus = rows.map(\.cpu)
        XCTAssertEqual(cpus, cpus.sorted(by: >), "sorted by CPU descending")
    }
}
