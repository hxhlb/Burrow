//
//  BackupStatus.swift
//  Burrow
//
//  Backup awareness (roadmap D.14, backup half): how stale is Time Machine?
//  Runs `tmutil latestbackup` (fast, unprivileged) and reduces it to a
//  days-ago count via the tested TimeMachine parser. Used by the Doctor check
//  (GUI + burrow_doctor). The SMART/IOKit half of D.14 is separate native work.
//

import Foundation

enum BackupStatus {
    /// Whole days since the most recent Time Machine backup, or nil when there
    /// are no backups / Time Machine is unavailable.
    static func lastBackupDaysAgo(now: Date = Date()) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        p.arguments = ["latestbackup"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let token = TimeMachine.latestBackupToken(text),
              let date = TimeMachine.date(fromToken: token) else { return nil }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }
}
