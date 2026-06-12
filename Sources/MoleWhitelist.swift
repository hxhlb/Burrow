//
//  MoleWhitelist.swift
//  Burrow
//
//  Typed access to Mole's protection file: ~/.config/mole/whitelist, a
//  plain glob file, one pattern per line — `mo clean` / `mo optimize`
//  skip anything matching it. Two consumers:
//
//    * Settings ▸ Maintenance ▸ Protected Items — the user's permanent
//      patterns (list / add / remove). Clean review's "Always skip this"
//      writes here too.
//    * Clean review's selective clean — unticked items become a fenced
//      *session* block appended for exactly one `mo clean` run, then
//      removed. The fence keeps Burrow's transient excludes strictly
//      separate from the user's own entries: endSession restores the
//      file byte-for-byte, and a startup sweep clears any block a crash
//      left behind. We never blind-overwrite user entries.
//
//  The engine stays authoritative about deletion — Burrow only ever
//  *protects* paths; it never removes cache paths itself.
//

import Foundation

struct MoleWhitelist {
    static let sessionBegin = "# BEGIN burrow-session"
    static let sessionEnd   = "# END burrow-session"

    enum WhitelistError: LocalizedError {
        /// A session path would corrupt the file's line/fence structure
        /// (it contains a newline, or matches the fence marker text) —
        /// writing it could leave other paths unprotected or splice the
        /// user's entries into the swept block. Abort the run instead.
        case unwritablePath(String)

        var errorDescription: String? {
            if case .unwritablePath(let p) = self {
                return String(format: NSLocalizedString("this path can't be protected: %@", comment: ""), p)
            }
            return nil
        }
    }

    let fileURL: URL

    /// The real file `mo` reads.
    static let live = MoleWhitelist(
        fileURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/mole/whitelist"))

    // MARK: - The user's permanent patterns

    /// Patterns the user (or Mole's defaults) put there — session-block
    /// entries are Burrow plumbing and stay hidden.
    func patterns() -> [String] {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return Self.stripSessionBlock(raw)
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    func add(_ pattern: String) throws {
        let trimmed = pattern.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !patterns().contains(trimmed) else { return }
        var raw = try readForModify()
        if !raw.isEmpty, !raw.hasSuffix("\n") { raw += "\n" }
        raw += trimmed + "\n"
        try write(raw)
    }

    func remove(_ pattern: String) throws {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let kept = raw.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces) != pattern }
        try write(kept.joined(separator: "\n"))
    }

    // MARK: - Session block (transient excludes for one clean run)

    /// Append the fenced block protecting `paths` for the next `mo clean`.
    /// Replaces any existing block — sessions never stack.
    func beginSession(excluding paths: [String]) throws {
        try endSession()
        guard !paths.isEmpty else { return }
        // mo reads these lines as GLOB PATTERNS: a literal path containing
        // `*?[]\` would not match itself, silently leaving the un-ticked
        // item unprotected — the fail-dangerous case the review screen
        // exists to prevent. Escape every path so it matches exactly
        // itself; refuse paths that would break the line/fence structure.
        let escaped = try paths.map { path -> String in
            let trimmed = path.trimmingCharacters(in: .whitespaces)
            guard !path.contains("\n"), !path.contains("\r"),
                  trimmed != Self.sessionBegin, trimmed != Self.sessionEnd else {
                throw WhitelistError.unwritablePath(path)
            }
            return Self.globEscaped(path)
        }
        var raw = try readForModify()
        if !raw.isEmpty, !raw.hasSuffix("\n") { raw += "\n" }
        raw += Self.sessionBegin + "\n"
            + escaped.joined(separator: "\n") + "\n"
            + Self.sessionEnd + "\n"
        try write(raw)
    }

    /// Escape glob metacharacters so a literal path matches exactly itself
    /// (the engine's matcher treats `\` as the escape, per Go's
    /// `filepath.Match`). User-entered patterns are NOT escaped — globs are
    /// the whole point there; only session paths are literals.
    static func globEscaped(_ path: String) -> String {
        var out = ""
        out.reserveCapacity(path.count + 4)
        for ch in path {
            if ch == "*" || ch == "?" || ch == "[" || ch == "]" || ch == "\\" {
                out.append("\\")
            }
            out.append(ch)
        }
        return out
    }

    /// Read for a read-modify-write. Missing file → "" (we'll create it);
    /// EXISTS-but-unreadable → throw. Falling back to "" there would make
    /// the next write WIPE the user's curated patterns — fail safe instead;
    /// the caller aborts its run.
    private func readForModify() throws -> String {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return "" }
        return try String(contentsOf: fileURL, encoding: .utf8)
    }

    /// Remove the fenced block, restoring the user's file exactly. Safe to
    /// call when no session exists — also the startup crash sweep.
    func endSession() throws {
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return }
        let swept = Self.stripSessionBlock(raw)
        if swept != raw { try write(swept) }
    }

    /// Drop every fenced block (stale ones included). An unterminated
    /// fence — a crash mid-write — swallows the rest of the file, which is
    /// correct: everything after an orphan fence is Burrow's, not the user's.
    static func stripSessionBlock(_ content: String) -> String {
        var out: [String] = []
        var inBlock = false
        for line in content.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == sessionBegin { inBlock = true; continue }
            if t == sessionEnd { inBlock = false; continue }
            if !inBlock { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    private func write(_ content: String) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
