//
//  OptimizeView.swift
//  Burrow
//
//  The Optimize tab — mole.fit's "Mercury" one-tap maintenance, our
//  brand. "Optimize" runs the safe maintenance tasks (elevated through a
//  single auth prompt so there aren't repeated password dialogs);
//  "Preview" is a no-auth `--dry-run`. Results render through the shared
//  TaskReportView and finish on a done banner.
//

import SwiftUI

struct OptimizeView: View {
    @StateObject private var runner = CommandRunner()
    @State private var preview = false
    @State private var pendingRun: ((Bool) -> Void)? = nil

    var body: some View {
        if runner.phase == .idle {
            if pendingRun != nil {
                FullDiskAccessRequired(
                    accent: Tool.optimize.accent,
                    onRecheck: { if Privacy.hasFullDiskAccess() { runPending(elevate: false) } },
                    onRunAnyway: { runPending(elevate: true) },
                    onCancel: { pendingRun = nil })
            } else {
                ToolHero(tool: .optimize, title: "Optimize", subtitle: Tool.optimize.tagline) {
                    PillButton(title: "Optimize") { runOptimize() }
                    PillButton(title: "Preview", filled: false) { runPreview() }
                }
            }
        } else {
            VStack(spacing: 0) {
                statusBar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                if isDone, !preview, !runner.wasCancelled {
                    DoneBanner(accent: Tool.optimize.accent, title: "Maintenance complete",
                               detail: "\(runner.groups.count) areas refreshed")
                }
                TaskReportView(groups: runner.groups, accent: Tool.optimize.accent)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isRunning { ProgressView().controlSize(.small).tint(Tool.optimize.accent) }
            Text(statusText).font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            if isRunning {
                Button { runner.cancel() } label: {
                    Label("Stop", systemImage: "stop.fill")
                        .font(Brand.mono(11)).foregroundStyle(Brand.red)
                }.buttonStyle(.plain)
            }
            if isDone {
                Button { runner.reset() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }
        }
    }

    private var isRunning: Bool { runner.phase == .running }
    private var isDone: Bool { if case .done = runner.phase { return true }; return false }

    private var statusText: String {
        switch runner.phase {
        case .running: return preview ? "Previewing maintenance…" : "Running maintenance…"
        case .done:    return runner.wasCancelled ? "Stopped."
            : (preview ? "Preview complete." : "Maintenance complete.")
        case .failed(let m): return "Failed: \(m)"
        case .idle:    return ""
        }
    }

    private func guarded(_ work: @escaping (Bool) -> Void) {
        if Privacy.hasFullDiskAccess() { work(false) } else { pendingRun = work }
    }
    private func runPending(elevate: Bool) { let r = pendingRun; pendingRun = nil; r?(elevate) }

    /// Optimize already runs elevated (root) → no flood, no gate.
    private func runOptimize() { preview = false; runner.run(["optimize"], elevated: true, label: "Optimizing") }
    private func runPreview() {
        guarded { elevate in preview = true; runner.run(["optimize", "--dry-run"], elevated: elevate, label: "Optimize preview") }
    }
}
