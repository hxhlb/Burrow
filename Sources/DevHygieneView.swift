//
//  DevHygieneView.swift
//  Burrow
//
//  Dev hygiene Home section (roadmap C.9, stage 1 = read-only). Lists each
//  developer ecosystem's cache/artifact roots (from DevHygiene.catalog) that
//  exist on disk, with their size, biggest first, and a reveal-in-Finder
//  affordance. Stage 2 (per-item delete via the ecosystem's own tool) is a
//  follow-up.
//
//  NOTE (hand-test): compile-verified only. Verify sizes look right and the
//  scan stays off the main thread on a machine with large caches.
//

import SwiftUI
import AppKit

struct DevHygieneView: View {
    private struct Row: Identifiable {
        let id = UUID()
        let ecosystem: String
        let path: String
        let bytes: Int64
    }

    @State private var rows: [Row] = []
    @State private var scanning = true
    @State private var clearTarget: Row?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(NSLocalizedString("Dev hygiene", comment: "")).font(.title2.bold())
                    if scanning { ProgressView().controlSize(.small).padding(.leading, 6) }
                }
                if !scanning, rows.isEmpty {
                    Text(NSLocalizedString("No developer caches found.", comment: ""))
                        .foregroundStyle(.secondary)
                }
                ForEach(rows) { r in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.ecosystem).font(.headline)
                            Text(r.path).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Text(Fmt.bytes(r.bytes)).font(.body.monospacedDigit())
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: r.path)])
                        } label: { Image(systemName: "magnifyingglass") }
                            .buttonStyle(.plain)
                            .help(NSLocalizedString("Reveal in Finder", comment: ""))
                        Button(NSLocalizedString("Clear", comment: "")) { clearTarget = r }
                            .buttonStyle(.bordered)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task { await scan() }
        .confirmationDialog(
            NSLocalizedString("Move this cache to the Trash?", comment: ""),
            isPresented: Binding(get: { clearTarget != nil },
                                 set: { if !$0 { clearTarget = nil } }),
            presenting: clearTarget
        ) { r in
            Button(NSLocalizedString("Move to Trash", comment: ""), role: .destructive) {
                try? FileManager.default.trashItem(at: URL(fileURLWithPath: r.path), resultingItemURL: nil)
                Task { await scan() }
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: { r in
            Text("\(r.ecosystem) — \(Fmt.bytes(r.bytes))\n\(r.path)")
        }
    }

    private func scan() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let found = await Task.detached(priority: .utility) { () -> [Row] in
            var out: [Row] = []
            for eco in DevHygiene.catalog(home: home) {
                for path in eco.paths where FileManager.default.fileExists(atPath: path) {
                    let bytes = Self.directorySize(path)
                    if bytes > 0 { out.append(Row(ecosystem: eco.name, path: path, bytes: bytes)) }
                }
            }
            return out.sorted { $0.bytes > $1.bytes }
        }.value
        rows = found
        scanning = false
    }

    /// Recursive allocated size of a directory. Off-main only.
    private static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in en {
            let v = try? file.resourceValues(forKeys: keys)
            total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        return total
    }
}
