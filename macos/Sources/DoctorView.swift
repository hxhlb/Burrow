//
//  DoctorView.swift
//  Burrow
//
//  Diagnostics Home section (roadmap I). Renders Doctor.report — engine,
//  Full Disk Access, memory pressure, disk headroom, recent errors — from the
//  latest snapshot + live permission/engine checks. Same verdict logic as the
//  burrow_doctor MCP tool.
//
//  NOTE (hand-test): verify the checks populate and the ok/warn/fail colours
//  read correctly against a real machine.
//

import SwiftUI

struct DoctorView: View {
    let db: DB
    @State private var checks: [Doctor.Check] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Diagnostics", comment: ""))
                    .font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)

                if checks.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(NSLocalizedString("Running checks…", comment: ""))
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    .padding(.vertical, 8)
                } else {
                    // One borderless card; checks separated by hairlines rather
                    // than boxed individually — matches the dashboard's read.
                    GlassCard {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(checks.enumerated()), id: \.offset) { i, c in
                                if i > 0 {
                                    Rectangle().fill(Brand.hairline).frame(height: 1)
                                }
                                row(c)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .fadeEdges()
        .task { await reload() }
    }

    private func row(_ c: Doctor.Check) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: glyph(c.level)).font(.system(size: 15))
                .foregroundStyle(tint(c.level)).frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text(c.detail).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(label(c.level)).font(Brand.mono(9, .medium)).foregroundStyle(tint(c.level))
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background(Capsule().fill(tint(c.level).opacity(0.14)))
        }
        .padding(.vertical, 10)
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
        case .ok:   return Brand.green
        case .warn: return Brand.gold
        case .fail: return Brand.red
        }
    }

    private func label(_ l: Doctor.Level) -> String {
        switch l {
        case .ok:   return NSLocalizedString("ok", comment: "")
        case .warn: return NSLocalizedString("warn", comment: "")
        case .fail: return NSLocalizedString("fail", comment: "")
        }
    }

    private func reload() async {
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
        let fullDiskAccess = Privacy.hasFullDiskAccess()
        let recentErrorCount = MetricsStore.driftCounters.decodeSkippedTotal
        // `tmutil latestbackup` and `system_profiler SPNVMeDataType` each spawn a
        // subprocess and block on waitUntilExit() — system_profiler routinely
        // takes seconds. Running them inline here (`.task` is MainActor-isolated)
        // froze the main thread long enough to trip Sentry's ≥2000ms App Hang
        // detector. Probe off the main thread, then publish on the main actor.
        let probes = await Task.detached(priority: .utility) {
            (backup: BackupStatus.lastBackupDaysAgo(), smart: DiskHealth.smartVerified())
        }.value
        checks = Doctor.report(.init(
            fullDiskAccess: fullDiskAccess,
            moInstalled: moInstalled, pressure: pressure,
            diskFreeBytes: free, diskTotalBytes: total,
            recentErrorCount: recentErrorCount,
            lastBackupDaysAgo: probes.backup,
            smartVerified: probes.smart))
    }
}
