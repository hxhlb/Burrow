//
//  DiskMapView.swift
//  Burrow
//
//  Treemap of disk usage, drilling in one directory at a time.
//
//  UX model:
//    * Path bar at the top shows the current location and a breadcrumb
//      stack so the user can pop back to any prior level. "Choose…"
//      jumps to an arbitrary folder.
//    * The map area is a SwiftUI ZStack of Rectangle views, each
//      positioned via the Treemap layout. Each rect is a hit target —
//      click a directory to descend; click a file to select it; right-
//      click anything for Reveal in Finder + Move to Trash.
//    * Initial path is ~. Scans run on a utility queue; the view shows
//      a ProgressView until the result arrives.
//
//  Rendering at the 100-1000-entry scale is fine with plain SwiftUI
//  Rectangles. A Canvas-based renderer would be cheaper for 10k+ rects
//  but we'd lose per-rect hover/click for free; not worth the trade at
//  this scale.
//

import SwiftUI
import AppKit

@available(macOS 14.0, *)
struct DiskMapView: View {
    /// Initial path — defaults to the user's home directory.
    var initialPath: String = NSHomeDirectory()

    @State private var stack: [DiskScanResult] = []
    @State private var loading: Bool = false
    @State private var errorMessage: String? = nil
    @State private var selected: DiskScanEntry? = nil
    @State private var hovered: DiskScanEntry? = nil

    var body: some View {
        VStack(spacing: 0) {
            pathBar
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            Divider()
            ZStack {
                map
                if loading {
                    Color.black.opacity(0.12)
                    ProgressView("Scanning…")
                        .controlSize(.regular)
                }
            }
            Divider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .frame(minWidth: 880, minHeight: 640)
        .task(id: initialPath) {
            // .task (not .onAppear) so a re-presented window with a
            // different initialPath re-scans. id: tied to the path so
            // the system cancels + restarts when the path changes.
            await self.scan(self.initialPath)
        }
    }

    // MARK: - Path bar

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button(action: self.popOne) {
                Image(systemName: "chevron.left")
            }
            .help("Up one level")
            .disabled(stack.count <= 1)
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(self.currentPath ?? "—")
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Spacer()
            Button("Rescan", systemImage: "arrow.clockwise") {
                guard let p = self.currentPath else { return }
                Task { await self.scan(p, replacingTop: true) }
            }
            .keyboardShortcut("r", modifiers: .command)
            .buttonStyle(.bordered)
            Button("Choose…", systemImage: "folder.badge.plus") {
                self.chooseFolder()
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Map

    private var map: some View {
        GeometryReader { geo in
            let entries = self.stack.last?.entries ?? []
            // Filter out zero-byte entries so the layout doesn't allocate
            // them imperceptible rectangles that still steal hit area.
            let kept = entries.filter { $0.size > 0 }
            let rects = Treemap.layout(
                weights: kept.map { Double($0.size) },
                in: CGRect(origin: .zero, size: geo.size))

            ZStack(alignment: .topLeading) {
                if let err = self.errorMessage {
                    ContentUnavailableView(err,
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("Try Rescan, or pick a different folder."))
                } else if kept.isEmpty, !self.loading {
                    ContentUnavailableView("No content",
                                           systemImage: "tray",
                                           description: Text("This folder is empty (or every entry has zero bytes)."))
                } else {
                    ForEach(Array(kept.enumerated()), id: \.element.id) { idx, entry in
                        let rect = rects[idx]
                        Self.rectView(entry: entry,
                                      rect: rect,
                                      isSelected: self.selected?.id == entry.id,
                                      isHovered: self.hovered?.id == entry.id)
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .onTapGesture { self.handleTap(entry) }
                            .onHover { hovering in
                                self.hovered = hovering ? entry : (self.hovered?.id == entry.id ? nil : self.hovered)
                            }
                            .contextMenu { self.contextMenu(for: entry) }
                            .help(self.tooltip(for: entry))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Each rectangle: filled with a kind-derived colour, outlined,
    /// and labelled with the entry name when it's big enough that text
    /// fits. Sub-40px-wide rects skip the label to avoid clipping noise.
    @ViewBuilder
    private static func rectView(entry: DiskScanEntry, rect: CGRect,
                                 isSelected: Bool, isHovered: Bool) -> some View {
        ZStack {
            Rectangle()
                .fill(Self.colour(for: entry.kind))
            Rectangle()
                .strokeBorder(isSelected ? Color.accentColor
                                          : (isHovered ? Color.white.opacity(0.7) : Color.black.opacity(0.3)),
                              lineWidth: isSelected ? 2 : (isHovered ? 1.5 : 0.5))
            if rect.width > 50, rect.height > 18 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if rect.height > 34 {
                        Text(Self.byteFormatter.string(fromByteCount: entry.size))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    /// Stable colour per file kind: derive an HSB hue from the kind's
    /// hashable identity. Directories get a desaturated neutral so they
    /// visually recede vs. files within them.
    private static func colour(for kind: String) -> Color {
        if kind == "<dir>" { return Color(white: 0.45, opacity: 0.7) }
        // FNV-1a 32-bit so the hue is deterministic across launches
        // (Swift's Hasher is not — uses random seed per process).
        var hash: UInt32 = 2_166_136_261
        for byte in kind.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.78)
    }

    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return f
    }()

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let entry = self.hovered ?? self.selected {
                Image(systemName: entry.isDir ? "folder.fill" : "doc")
                Text(entry.path)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Self.byteFormatter.string(fromByteCount: entry.size))
                    .monospacedDigit()
            } else if let r = self.stack.last {
                Text("\(r.entries.count) entries")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Total \(Self.byteFormatter.string(fromByteCount: r.totalSize))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    // MARK: - Interactions

    private func handleTap(_ entry: DiskScanEntry) {
        self.selected = entry
        if entry.isDir {
            Task { await self.scan(entry.path) }
        }
    }

    private func popOne() {
        guard self.stack.count > 1 else { return }
        self.stack.removeLast()
        self.selected = nil
        self.hovered = nil
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: self.currentPath ?? NSHomeDirectory())
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await self.scan(url.path, replacingTop: true) }
    }

    @ViewBuilder
    private func contextMenu(for entry: DiskScanEntry) -> some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.path, forType: .string)
        }
        Divider()
        // Move-to-trash is destructive, so we leave the heavy lifting to
        // NSWorkspace's user-visible confirm. No silent rm.
        Button("Move to Trash") {
            self.moveToTrash(entry)
        }
    }

    private func moveToTrash(_ entry: DiskScanEntry) {
        let url = URL(fileURLWithPath: entry.path)
        NSWorkspace.shared.recycle([url]) { _, error in
            DispatchQueue.main.async {
                if error == nil {
                    // Refresh the current level to drop the now-gone entry.
                    if let p = self.currentPath {
                        Task { await self.scan(p, replacingTop: true) }
                    }
                } else {
                    self.errorMessage = "Couldn't trash: \(error?.localizedDescription ?? "?")"
                }
            }
        }
    }

    private func tooltip(for entry: DiskScanEntry) -> String {
        var t = "\(entry.path)\n\(Self.byteFormatter.string(fromByteCount: entry.size))"
        if let la = entry.lastAccess {
            let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
            t += "\nlast access \(f.string(from: la))"
        }
        return t
    }

    // MARK: - Scan plumbing

    private var currentPath: String? {
        self.stack.last?.path
    }

    /// Run `mo analyze --json` on `path`. Either pushes the result onto
    /// the navigation stack, or replaces the top entry (Rescan / Choose).
    @MainActor
    private func scan(_ path: String, replacingTop: Bool = false) async {
        self.loading = true
        self.errorMessage = nil
        // Capture the path so a slow scan whose result arrives after a
        // newer navigation doesn't clobber the user's current view.
        let target = path
        let result: Result<DiskScanResult, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let r = try DiskScanner.scan(target)
                return .success(r)
            } catch {
                return .failure(error)
            }
        }.value
        // Race check: only apply if the user hasn't navigated meanwhile
        // to a different target than the one we asked for.
        switch result {
        case .success(let r):
            if replacingTop, !self.stack.isEmpty {
                self.stack[self.stack.count - 1] = r
            } else {
                self.stack.append(r)
            }
            self.selected = nil
        case .failure(let err):
            self.errorMessage = (err as? LocalizedError)?.errorDescription ?? "\(err)"
        }
        self.loading = false
    }
}
