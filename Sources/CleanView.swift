//
//  CleanView.swift
//  Burrow
//
//  The Clean tab — mole.fit's "Earth" flow, our brand. The hero offers
//  both a no-risk "Scan your Mac" preview (`mo clean --dry-run`) and a
//  direct "Clean Now" run. The real clean runs elevated through ONE auth
//  prompt (CommandRunner.runElevated) so you don't get a stack of
//  password dialogs, and finishes on a proper done banner.
//

import SwiftUI
import AppKit

struct CleanView: View {
    @StateObject private var runner = CommandRunner()
    @State private var mode: Mode = .dry
    @State private var pendingRun: ((Bool) -> Void)? = nil

    enum Mode { case dry, real }

    var body: some View {
        if runner.phase == .idle {
            if pendingRun != nil {
                FullDiskAccessRequired(
                    accent: Tool.clean.accent,
                    onRecheck: { if Privacy.hasFullDiskAccess() { runPending(elevate: false) } },
                    onRunAnyway: { runPending(elevate: true) },   // root bypasses TCC → no flood
                    onCancel: { pendingRun = nil })
            } else {
                ToolHero(tool: .clean, title: "Clean", subtitle: Tool.clean.tagline) {
                    PillButton(title: "Clean Now") { confirmReal() }
                    PillButton(title: "Preview", filled: false) { startDry() }
                }
            }
        } else {
            VStack(spacing: 0) {
                statusBar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                if isDone, mode == .real {
                    DoneBanner(accent: Tool.clean.accent, title: "Cleaned",
                               detail: runner.summary.map { "Freed up to \($0.space) · \($0.items) items" })
                } else if mode == .dry, let s = runner.summary {
                    summaryBanner(s)
                }
                TaskReportView(groups: runner.groups, accent: Tool.clean.accent)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            if isRunning { ProgressView().controlSize(.small).tint(Tool.clean.accent) }
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

    private func summaryBanner(_ s: TaskSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(s.space.isEmpty ? "—" : s.space)
                .font(Brand.mono(24, .semibold)).foregroundStyle(Tool.clean.accent)
            Text("to free").font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
            if !s.items.isEmpty {
                Text("· \(s.items) items · \(s.categories) categories")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private var isRunning: Bool { runner.phase == .running }
    private var isDone: Bool { if case .done = runner.phase { return true }; return false }

    private var statusText: String {
        switch runner.phase {
        case .running: return mode == .dry ? "Scanning your Mac…" : "Cleaning… don't quit."
        case .done:    return runner.wasCancelled ? "Stopped."
            : (mode == .dry ? "Preview — review, then clean for real." : "Done — caches cleared.")
        case .failed(let m): return "Failed: \(m)"
        case .idle:    return ""
        }
    }

    // MARK: - Full Disk Access gate

    /// Run a flood-prone scan. With Full Disk Access we run it directly.
    /// Without, divert to the gate; the user either grants FDA (then we run
    /// normally) or picks "Scan with admin", which runs the same command
    /// elevated — root bypasses TCC, so one password replaces the flood.
    /// `work(elevate)` decides whether to run via sudo.
    private func guarded(_ work: @escaping (Bool) -> Void) {
        if Privacy.hasFullDiskAccess() { work(false) } else { pendingRun = work }
    }
    private func runPending(elevate: Bool) { let r = pendingRun; pendingRun = nil; r?(elevate) }

    private func startDry() {
        guarded { elevate in
            mode = .dry
            runner.run(["clean", "--dry-run"], elevated: elevate, label: "Scanning caches")
        }
    }

    /// The real clean already runs elevated (root), so it never triggers the
    /// flood — no gate needed here.
    private func confirmReal() {
        let alert = NSAlert()
        alert.messageText = "Clean caches for real?"
        alert.informativeText = "Burrow will run `mo clean` with administrator rights. Cache files are removed permanently; Mole's whitelist and safety rules still apply."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clean")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        mode = .real
        runner.run(["clean"], elevated: true, label: "Cleaning caches")
    }
}
