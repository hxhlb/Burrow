//
//  Doctor.swift
//  Burrow
//
//  Diagnostics report (roadmap I / appendix parity gap): a one-glance health
//  check from the Help menu — permissions, memory pressure, disk headroom,
//  the engine, recent errors. This is the pure half: system facts in, ranked
//  verdicts out, so the same logic backs the Help-menu sheet and (later) a
//  `burrow_doctor` MCP tool. Gathering the facts (TCC state, pressure, log
//  scan) is the integration half.
//

import Foundation

enum Doctor {
    enum Level: Int { case ok, warn, fail }  // Int so callers can sort worst-first
    enum MemoryPressure { case normal, warning, critical }

    struct Check: Equatable {
        let name: String
        let level: Level
        let detail: String
    }

    struct Input {
        var fullDiskAccess: Bool
        var moInstalled: Bool
        var pressure: MemoryPressure
        var diskFreeBytes: Int64
        var diskTotalBytes: Int64
        var recentErrorCount: Int
        /// Days since the last Time Machine backup; nil = none found / unknown.
        var lastBackupDaysAgo: Int? = nil
    }

    /// One `Check` per facet, in a stable order. Each verdict is independent;
    /// callers can sort by `level` to surface failures first.
    static func report(_ i: Input) -> [Check] {
        [engine(i), permissions(i), memory(i), disk(i), backup(i), errors(i)]
    }

    private static func engine(_ i: Input) -> Check {
        i.moInstalled
            ? Check(name: "Engine", level: .ok, detail: "mo is installed")
            : Check(name: "Engine", level: .fail, detail: "mo is not installed — core features are unavailable")
    }

    private static func permissions(_ i: Input) -> Check {
        i.fullDiskAccess
            ? Check(name: "Full Disk Access", level: .ok, detail: "granted")
            : Check(name: "Full Disk Access", level: .warn, detail: "off — some scans and cleanups are limited")
    }

    private static func memory(_ i: Input) -> Check {
        switch i.pressure {
        case .normal:   return Check(name: "Memory pressure", level: .ok, detail: "normal")
        case .warning:  return Check(name: "Memory pressure", level: .warn, detail: "elevated")
        case .critical: return Check(name: "Memory pressure", level: .fail, detail: "critical — the system is low on memory")
        }
    }

    private static func disk(_ i: Input) -> Check {
        guard i.diskTotalBytes > 0 else {
            return Check(name: "Disk space", level: .warn, detail: "unknown")
        }
        let freePct = Double(i.diskFreeBytes) / Double(i.diskTotalBytes) * 100
        if freePct < 5 {
            return Check(name: "Disk space", level: .fail, detail: "under 5% free")
        } else if freePct < 10 {
            return Check(name: "Disk space", level: .warn, detail: "under 10% free")
        }
        return Check(name: "Disk space", level: .ok, detail: "\(Int(freePct.rounded()))% free")
    }

    private static func backup(_ i: Input) -> Check {
        guard let days = i.lastBackupDaysAgo else {
            return Check(name: "Backups", level: .warn, detail: "no recent Time Machine backup found")
        }
        if days > 14 {
            return Check(name: "Backups", level: .warn, detail: "last backup \(days) days ago")
        }
        return Check(name: "Backups", level: .ok, detail: "last backup \(days) day\(days == 1 ? "" : "s") ago")
    }

    private static func errors(_ i: Input) -> Check {
        i.recentErrorCount == 0
            ? Check(name: "Recent errors", level: .ok, detail: "none logged")
            : Check(name: "Recent errors", level: .warn, detail: "\(i.recentErrorCount) in recent logs")
    }
}
