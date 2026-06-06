//
//  DiskScanner.swift
//  Burrow
//
//  Thin wrapper around `mo analyze --json <path>`. Mole already does
//  the heavy lifting (recursive size aggregation per directory, fast
//  parallel walk) — we just spawn it, parse the JSON, and return typed
//  entries. The treemap layer reads from the entries list.
//
//  Mole returns only the immediate children of the requested path, with
//  their aggregate sizes. The drill-in UX (click a directory to descend)
//  means we don't need to recurse upfront — each level is one mo call.
//
//  Why not FileManager.enumerator: Mole's analyze-go walks via
//  getattrlistbulk which is ~10× faster than NSFileManager for large
//  trees, plus we get parity with `mo analyze` from the CLI — same path
//  scanned interactively from Burrow gives the same numbers.
//

import Foundation

struct DiskScanEntry: Identifiable, Hashable {
    let id: String       // absolute path; stable identity for hit-testing
    let name: String     // display name (last path component)
    let path: String     // full absolute path
    let size: Int64      // bytes; for directories this is the recursive aggregate
    let isDir: Bool
    let lastAccess: Date?

    /// Best-guess file kind for colouring. Extension if present,
    /// "<dir>" for directories, "" for unknown. Used as the colour key.
    var kind: String {
        if self.isDir { return "<dir>" }
        let url = URL(fileURLWithPath: self.path)
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? "<none>" : ext
    }
}

struct DiskScanResult {
    let path: String
    let totalSize: Int64
    let totalFiles: Int
    let entries: [DiskScanEntry]
    let scannedAt: Date
}

enum DiskScanError: Error, LocalizedError {
    case moNotFound
    case moFailed(exitCode: Int32, stderr: String)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .moNotFound:
            return NSLocalizedString("Mole CLI (`mo`) not found on PATH.", comment: "")
        case .moFailed(let code, let stderr):
            return String(format: NSLocalizedString("mo analyze exited %d: %@", comment: ""),
                          code, String(stderr.prefix(200)))
        case .parseFailed(let m):
            return String(format: NSLocalizedString("Couldn't parse mo analyze output: %@", comment: ""), m)
        }
    }
}

enum DiskScanner {
    /// Scan a single path level via `mo analyze --json`. Synchronous —
    /// callers must run on a background queue. Returns aggregated sizes
    /// for each direct child; drill in by calling again with the child's
    /// path.
    static func scan(_ path: String) throws -> DiskScanResult {
        if isSamePath(path, NSHomeDirectory()) {
            return try scanHome(path)
        }
        return try scanWithMole(path)
    }

    static func shouldSkipInHomeScan(_ path: String, homeDirectory: String = NSHomeDirectory()) -> Bool {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let homeURL = URL(fileURLWithPath: homeDirectory).standardizedFileURL
        return url.deletingLastPathComponent().path == homeURL.path && url.lastPathComponent == "Library"
    }

    private static func scanWithMole(_ path: String) throws -> DiskScanResult {
        guard MoleCLI.findExecutable() != nil else {
            throw DiskScanError.moNotFound
        }
        // 5-minute timeout — `mo analyze` on a large directory is usually a
        // few seconds, but a cold cache + large external volume + no
        // indexing can stretch it. Beyond 5 min something's wrong.
        let result = try MoleCLI.run(args: ["analyze", "--json", path], timeout: 300)
        guard result.exitCode == 0 else {
            throw DiskScanError.moFailed(exitCode: result.exitCode, stderr: result.stderr)
        }
        guard let data = result.stdout.data(using: .utf8) else {
            throw DiskScanError.parseFailed("non-utf8 stdout")
        }
        return try Self.parse(data)
    }

    private static func scanHome(_ path: String) throws -> DiskScanResult {
        let homeURL = URL(fileURLWithPath: path)
        let urls = try FileManager.default.contentsOfDirectory(
            at: homeURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        ).filter { !shouldSkipInHomeScan($0.path, homeDirectory: path) }

        let sizes = try topLevelSizes(urls.map(\.path))
        var entries: [DiskScanEntry] = []
        entries.reserveCapacity(urls.count)
        for url in urls {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = sizes[url.path] ?? (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            entries.append(DiskScanEntry(
                id: url.path,
                name: url.lastPathComponent,
                path: url.path,
                size: size,
                isDir: values?.isDirectory ?? false,
                lastAccess: attrs?[.modificationDate] as? Date
            ))
        }
        entries.sort { $0.size > $1.size }
        let total = entries.reduce(0) { $0 + $1.size }
        return DiskScanResult(
            path: path,
            totalSize: total,
            totalFiles: entries.count,
            entries: entries,
            scannedAt: Date()
        )
    }

    private static func topLevelSizes(_ paths: [String]) throws -> [String: Int64] {
        guard !paths.isEmpty else { return [:] }
        let result = try MoleCLI.run(args: ["-sk"] + paths, executable: "/usr/bin/du", timeout: 300)
        var sizes: [String: Int64] = [:]
        for line in result.stdout.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0].trimmingCharacters(in: .whitespaces)) else { continue }
            sizes[String(parts[1])] = kb * 1024
        }
        return sizes
    }

    private static func isSamePath(_ lhs: String, _ rhs: String) -> Bool {
        URL(fileURLWithPath: lhs).standardizedFileURL.path == URL(fileURLWithPath: rhs).standardizedFileURL.path
    }

    // MARK: - Parsing

    /// Decode mo's JSON output into our typed shape. Loose decoding —
    /// any field we don't expose can change upstream without breaking
    /// us; we only fail if the spine (`entries[*].name`, `path`,
    /// `size`, `is_dir`) drifts.
    static func parse(_ data: Data) throws -> DiskScanResult {
        let raw: [String: Any]
        do {
            raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        } catch {
            throw DiskScanError.parseFailed(error.localizedDescription)
        }

        let path = raw["path"] as? String ?? "?"
        let totalSize = (raw["total_size"] as? Int64)
            ?? Int64(raw["total_size"] as? Int ?? 0)
        let totalFiles = raw["total_files"] as? Int ?? 0
        let entriesRaw = raw["entries"] as? [[String: Any]] ?? []

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var entries: [DiskScanEntry] = []
        entries.reserveCapacity(entriesRaw.count)
        for e in entriesRaw {
            guard let name = e["name"] as? String,
                  let path = e["path"] as? String else { continue }
            let size = (e["size"] as? Int64) ?? Int64(e["size"] as? Int ?? 0)
            let isDir = e["is_dir"] as? Bool ?? false
            var lastAccess: Date? = nil
            if let s = e["last_access"] as? String {
                lastAccess = iso.date(from: s) ?? isoNoFrac.date(from: s)
            }
            entries.append(DiskScanEntry(
                id: path,
                name: name,
                path: path,
                size: size,
                isDir: isDir,
                lastAccess: lastAccess
            ))
        }
        // Largest first — gives the treemap a natural sort + matches
        // what `mo analyze`'s TUI shows.
        entries.sort { $0.size > $1.size }

        return DiskScanResult(
            path: path,
            totalSize: totalSize,
            totalFiles: totalFiles,
            entries: entries,
            scannedAt: Date()
        )
    }
}
