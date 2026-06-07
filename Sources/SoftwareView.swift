//
//  SoftwareView.swift
//  Burrow
//
//  The Software tab — Burrow's take on mole.fit's "Mars" screen. Lists
//  installed apps from `mo uninstall --list` (which conveniently emits
//  JSON: name, bundle id, source, path, size), with search + sort and a
//  multi-select uninstall flow. Updates is stubbed for now.
//
//  Uninstall is destructive-ish (defaults to Trash, recoverable) so it
//  always goes through an explicit confirm sheet before `mo uninstall`
//  runs.
//

import SwiftUI
import AppKit
import CoreServices

struct InstalledApp: Identifiable {
    let id: String
    let name: String
    let bundleId: String
    let source: String
    let uninstallName: String
    let path: String
    let sizeStr: String
    let sizeBytes: Int64
    let lastUsed: Date?
}

enum AppSort: String, CaseIterable { case size = "Size", name = "Name", recent = "Recent", source = "Source" }
enum SoftwareSegment { case uninstall, updates }

struct SoftwareView: View {
    @StateObject private var model = SoftwareModel()
    @StateObject private var updates = UpdatesModel()
    var isActive: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
            if model.segment == .uninstall {
                Rectangle().fill(Brand.hairline).frame(height: 1)
                bottomBar.padding(.horizontal, 18).padding(.vertical, 10)
            }
        }
        .onAppear { if isActive { model.startIfNeeded() } }
        .onChange(of: isActive) { _, now in if now { model.startIfNeeded() } }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            segmented
            Spacer()
            if model.segment == .uninstall {
                ForEach(AppSort.allCases, id: \.self) { s in
                    Button { model.setSort(s) } label: {
                        Text(s.rawValue.lowercased())
                            .font(Brand.mono(11, model.sort == s ? .semibold : .regular))
                            .foregroundStyle(model.sort == s ? Tool.apps.accent : Brand.textSecondary)
                    }.buttonStyle(.plain)
                }
                searchField
            }
        }
    }

    private var segmented: some View {
        HStack(spacing: 2) {
            seg("Uninstall", .uninstall)
            seg("Updates", .updates)
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func seg(_ title: String, _ value: SoftwareSegment) -> some View {
        let on = model.segment == value
        return Button { model.segment = value } label: {
            Text(title).font(Brand.mono(11, on ? .semibold : .regular))
                .foregroundStyle(on ? .black : Brand.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background { if on { Capsule().fill(.white) } }
                .contentShape(Capsule())
        }.buttonStyle(.plain)
    }

    private var searchField: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Brand.textTertiary)
            TextField("Search apps", text: $model.query)
                .textFieldStyle(.plain).font(Brand.sans(12)).frame(width: 130)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        if model.segment == .updates {
            UpdatesView(model: updates)
        } else if model.loading {
            VStack { Spacer(); ProgressView("Reading installed apps…").controlSize(.large).tint(Tool.apps.accent)
                .font(Brand.mono(11)); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.filtered) { app in
                        AppRow(app: app, selected: model.selected.contains(app.id)) {
                            model.toggle(app.id)
                        }
                        Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 58)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .scrollIndicators(.visible)
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(model.selectionLabel).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Button {
                model.confirmAndUninstall()
            } label: {
                Text("Uninstall\(model.selected.isEmpty ? "" : " (\(model.selected.count))")")
                    .font(Brand.sans(12, .semibold))
                    .foregroundStyle(model.selected.isEmpty ? Brand.textTertiary : .white)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .background(Capsule().fill(model.selected.isEmpty ? Color.white.opacity(0.06) : Tool.apps.accent))
            }
            .buttonStyle(.plain)
            .disabled(model.selected.isEmpty)
        }
    }
}

struct AppRow: View {
    let app: InstalledApp
    let selected: Bool
    let onToggle: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: SoftwareIcons.icon(app.path)).resizable().frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).font(Brand.sans(13, .medium)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                Text("\(app.sizeStr) · \(app.source) · \(prettyPath)")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 8)
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 17))
                .foregroundStyle(selected ? Tool.apps.accent : Brand.textTertiary)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hover ? Brand.cardFillHover : Color.clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onTapGesture { onToggle() }
    }

    private var prettyPath: String {
        app.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }
}

enum SoftwareIcons {
    private static var cache: [String: NSImage] = [:]
    static func icon(_ path: String) -> NSImage {
        if let c = cache[path] { return c }
        let img = NSWorkspace.shared.icon(forFile: path)
        cache[path] = img
        return img
    }
}

@MainActor
final class SoftwareModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    @Published var error: String?
    @Published var query = ""
    @Published var sort: AppSort = .size
    @Published var selected: Set<String> = []
    @Published var segment: SoftwareSegment = .uninstall
    private var started = false

    var filtered: [InstalledApp] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty ? apps : apps.filter { $0.name.lowercased().contains(q) }
        switch sort {
        case .size:   return base.sorted { $0.sizeBytes > $1.sizeBytes }
        case .name:   return base.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .recent: return base.sorted { ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast) }
        case .source: return base.sorted { $0.source < $1.source }
        }
    }

    var selectionLabel: String {
        if selected.isEmpty { return "\(apps.count) apps" }
        let total = apps.filter { selected.contains($0.id) }.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return "\(selected.count) selected · \(Fmt.bytes(total))"
    }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        load()
    }

    func setSort(_ s: AppSort) {
        sort = s
        if s == .recent { ensureRecentDates() }
    }

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private var recentLoaded = false

    /// "Last used" needs a Spotlight query per app — only worth it when the
    /// user actually sorts by Recent, not on every Software-tab open.
    private func ensureRecentDates() {
        guard !recentLoaded, !apps.isEmpty else { return }
        recentLoaded = true
        let snapshot = apps
        DispatchQueue.global(qos: .userInitiated).async {
            let dated = snapshot.map { a in
                InstalledApp(id: a.id, name: a.name, bundleId: a.bundleId, source: a.source,
                             uninstallName: a.uninstallName, path: a.path, sizeStr: a.sizeStr,
                             sizeBytes: a.sizeBytes, lastUsed: Self.lastUsedDate(a.path))
            }
            Task { @MainActor in self.apps = dated }
        }
    }

    func load() {
        loading = true
        error = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = Self.fetch()
            Task { @MainActor in
                self.apps = parsed
                self.loading = false
                self.recentLoaded = false
                if self.sort == .recent { self.ensureRecentDates() }
            }
        }
    }

    private static func fetch() -> [InstalledApp] {
        // `mo uninstall --list` computes a size for every installed app,
        // which can take a while on a full /Applications — give it room.
        guard let res = try? MoleCLI.run(args: ["uninstall", "--list"], timeout: 180),
              res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return arr.compactMap { d in
            guard let name = d["name"] as? String,
                  let path = d["path"] as? String else { return nil }
            let sizeStr = d["size"] as? String ?? "--"
            return InstalledApp(
                id: (d["bundle_id"] as? String).map { $0 + "|" + path } ?? path,
                name: name,
                bundleId: d["bundle_id"] as? String ?? "",
                source: d["source"] as? String ?? "App",
                uninstallName: d["uninstall_name"] as? String ?? name,
                path: path,
                sizeStr: sizeStr,
                sizeBytes: parseSize(sizeStr),
                lastUsed: nil)   // computed lazily, only when sorting by Recent
        }
    }

    /// Best-effort "last used": Spotlight's kMDItemLastUsedDate when it's
    /// available, else the bundle's access/modification date.
    private static func lastUsedDate(_ path: String) -> Date? {
        if let item = MDItemCreate(nil, path as CFString),
           let v = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            return v
        }
        let url = URL(fileURLWithPath: path)
        if let vals = try? url.resourceValues(forKeys: [.contentAccessDateKey, .contentModificationDateKey]) {
            return vals.contentAccessDate ?? vals.contentModificationDate
        }
        return nil
    }

    static func parseSize(_ s: String) -> Int64 {
        let t = s.trimmingCharacters(in: .whitespaces).uppercased()
        if t == "--" || t.isEmpty { return 0 }
        let units: [(String, Double)] = [("TB", 1_099_511_627_776), ("GB", 1_073_741_824),
                                         ("MB", 1_048_576), ("KB", 1024), ("B", 1)]
        for (u, mult) in units where t.hasSuffix(u) {
            let num = Double(t.dropLast(u.count).trimmingCharacters(in: .whitespaces)) ?? 0
            return Int64(num * mult)
        }
        return Int64(Double(t) ?? 0)
    }

    /// Confirm, then run `mo uninstall <names>` (Trash-based). User action
    /// only — gated behind an explicit modal.
    func confirmAndUninstall() {
        let targets = apps.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "Uninstall \(targets.count) app\(targets.count == 1 ? "" : "s")?"
        alert.informativeText = "These move to the Trash (recoverable):\n\n"
            + targets.map { "• \($0.name)" }.joined(separator: "\n")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let names = targets.map { $0.uninstallName }
        loading = true
        // Surface the run in the menu-bar HUD's Activity section too.
        let opId = UUID()
        OperationCenter.shared.begin(opId, label: "Uninstalling \(targets.count) app\(targets.count == 1 ? "" : "s")")
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? MoleCLI.run(args: ["uninstall"] + names, timeout: 300)
            let parsed = Self.fetch()
            Task { @MainActor in
                self.apps = parsed
                self.selected = []
                self.loading = false
                // Re-fetched apps have lastUsed == nil; recompute dates if the
                // user is still sorting by Recent (mirror load()), else Recent
                // would silently collapse after an uninstall.
                self.recentLoaded = false
                if self.sort == .recent { self.ensureRecentDates() }
                OperationCenter.shared.end(opId, success: (res?.exitCode ?? 1) == 0,
                                           detail: "\(targets.count) moved to Trash")
            }
        }
    }
}
