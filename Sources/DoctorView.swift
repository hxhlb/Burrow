//
//  DoctorView.swift
//  Burrow
//
//  Diagnostics Home section (roadmap I). Renders Doctor.report — engine,
//  Full Disk Access, memory pressure, disk headroom, recent errors — from the
//  latest snapshot + live permission/engine checks. Same verdict logic as the
//  burrow_doctor MCP tool.
//
//  NOTE (hand-test): compile-verified only. Verify the checks populate and the
//  ok/warn/fail colours read correctly against a real machine.
//

import SwiftUI

struct DoctorView: View {
    let db: DB
    @State private var checks: [Doctor.Check] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(NSLocalizedString("Diagnostics", comment: "")).font(.title2.bold())
                ForEach(Array(checks.enumerated()), id: \.offset) { _, c in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: glyph(c.level)).foregroundStyle(tint(c.level))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name).font(.headline)
                            Text(c.detail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task { reload() }
    }

    private func glyph(_ l: Doctor.Level) -> String {
        switch l {
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        case .fail: return "xmark.octagon.fill"
        }
    }

    private func tint(_ l: Doctor.Level) -> Color {
        switch l {
        case .ok:   return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }

    private func reload() {
        let latest = MetricsStore(db: db).latest()?.status
        var free: Int64 = 0, total: Int64 = 0
        if let d = latest?.disks.max(by: { $0.total < $1.total }) {
            total = Int64(d.total)
            free = Int64(d.total > d.used ? d.total - d.used : 0)
        }
        let moInstalled: Bool
        if case .installed = MoEngine.shared.availability() { moInstalled = true } else { moInstalled = false }
        let p = (latest?.memory.pressure ?? "").lowercased()
        let pressure: Doctor.MemoryPressure = p.contains("critical") ? .critical
            : (p.contains("warn") ? .warning : .normal)
        checks = Doctor.report(.init(
            fullDiskAccess: Privacy.hasFullDiskAccess(),
            moInstalled: moInstalled, pressure: pressure,
            diskFreeBytes: free, diskTotalBytes: total,
            recentErrorCount: MetricsStore.driftCounters.decodeSkippedTotal,
            lastBackupDaysAgo: BackupStatus.lastBackupDaysAgo()))
    }
}
