//
//  RestoreView.swift
//  Burrow
//
//  "Restore last cleanup" pane (roadmap D.13). Reads Mole's deletion log,
//  builds a RestorePlan, and offers to put each Trash-based removal back.
//  Honest by construction: cache deletions (action "remove") are permanent and
//  shown locked; only trashed items with a free original path are restorable.
//
//  NOTE (hand-test): compile-verified only. Verify against a real cleanup —
//  the ~/.Trash fallback move and collision handling need a live Trash.
//

import SwiftUI

struct RestoreView: View {
    private struct Row: Identifiable { let id = UUID(); let entry: RestorePlan.Entry }

    @State private var rows: [Row] = []
    @State private var loading = true

    private var logPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/mole/deletions.log")
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(NSLocalizedString("Restore last cleanup", comment: "")).font(.title2.bold())
                Text(NSLocalizedString("Only Trash-based removals can be restored — cache deletions are permanent.", comment: ""))
                    .font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView().controlSize(.small) }
                ForEach(rows) { r in
                    HStack(spacing: 10) {
                        Image(systemName: r.entry.restorable ? "arrow.uturn.backward.circle" : "lock.circle")
                            .foregroundStyle(r.entry.restorable ? Color.green : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text((r.entry.path as NSString).lastPathComponent).font(.headline)
                            Text(r.entry.reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if r.entry.restorable {
                            Button(NSLocalizedString("Restore", comment: "")) { restore(r.entry) }
                                .buttonStyle(.bordered)
                        }
                    }
                }
                if !loading, rows.isEmpty {
                    Text(NSLocalizedString("No restorable items found.", comment: "")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task { await reload() }
    }

    private func reload() async {
        let path = logPath
        let entries = await Task.detached(priority: .utility) { () -> [RestorePlan.Entry] in
            let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            let items = RestorePlan.parseLog(text)
            return RestorePlan.build(items, existsAtOriginal: { FileManager.default.fileExists(atPath: $0) })
        }.value
        rows = entries.map { Row(entry: $0) }
        loading = false
    }

    /// Fallback restore: find the item by name in ~/.Trash and move it back to
    /// its recorded origin, skipping on collision. (Finder "put back" needs
    /// Finder's own metadata; this works without it.)
    private func restore(_ entry: RestorePlan.Entry) {
        let name = (entry.path as NSString).lastPathComponent
        let trashed = (NSHomeDirectory() as NSString).appendingPathComponent(".Trash/\(name)")
        let fm = FileManager.default
        if fm.fileExists(atPath: trashed), !fm.fileExists(atPath: entry.path) {
            try? fm.moveItem(atPath: trashed, toPath: entry.path)
        }
        Task { await reload() }
    }
}
