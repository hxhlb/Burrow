//
//  MoInteractive.swift
//  Burrow
//
//  Drives Mole's INTERACTIVE selection TUIs (`mo installer`, `mo purge`)
//  from the GUI so the user can pick WHICH items to remove — and Mole
//  itself does the deletion. Mole exposes no flags/JSON for targeted
//  removal; its only selection is the on-screen checklist. So Burrow runs
//  `mo` in a pseudo-terminal, parses that checklist into a native list,
//  and replays the user's choices as keystrokes (↓ / Space / Enter).
//
//  The pure parts here — parsing a screen and planning keystrokes — are
//  unit-tested. The PTY plumbing (PTYTask / MoInteractiveRunner) is the
//  thin impure seam. Crucially, after sending the toggles we RE-READ the
//  screen and verify the selection matches before pressing Enter, so a
//  parsing/cursor bug can never make Mole delete the wrong thing.
//

import Foundation
import Darwin   // openpty, winsize

// MARK: - Parsed TUI model

struct MoTUIItem: Equatable {
    let name: String
    let size: String        // as Mole prints it, e.g. "1.26GB"
    let location: String    // e.g. "Desktop"
    let selected: Bool      // ● vs ○
}

struct MoTUIScreen: Equatable {
    let items: [MoTUIItem]
    let cursor: Int          // index with the ➤ marker
    let selectedCount: Int?  // from the "N selected" header, if present
}

enum MoTUI {
    // Glyphs Mole's TUI uses.
    private static let unchecked: Character = "\u{25CB}"  // ○
    private static let checked: Character = "\u{25CF}"    // ●
    private static let cursorMark: Character = "\u{27A4}" // ➤

    /// Parse the LAST rendered frame of a Mole selection TUI. The TUI
    /// redraws the whole list each keystroke; each frame begins with a
    /// "… N selected" header, so resetting on every header leaves us with
    /// the most recent frame's state.
    static func parse(_ raw: String) -> MoTUIScreen {
        let text = stripANSI(raw)
        var items: [MoTUIItem] = []
        var cursor = 0
        var selectedCount: Int?

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if let n = selectedCountIn(line) {       // header → start a fresh frame
                selectedCount = n
                items = []
                cursor = 0
                continue
            }
            guard let (item, isCursor) = parseItem(line) else { continue }
            if isCursor { cursor = items.count }
            items.append(item)
        }
        return MoTUIScreen(items: items, cursor: cursor, selectedCount: selectedCount)
    }

    /// The indices currently checked (●) in a screen.
    static func selectedIndices(_ screen: MoTUIScreen) -> Set<Int> {
        Set(screen.items.enumerated().filter { $0.element.selected }.map { $0.offset })
    }

    /// Keystrokes to take a FRESH list (cursor at item 0, everything ○) to
    /// exactly `wanted` checked. Walks every item top-to-bottom once,
    /// pressing Space only on wanted ones — deterministic, no cursor math.
    /// `confirm` appends Enter. Does NOT confirm an empty selection.
    static func keystrokesToSelect(_ wanted: Set<Int>, count: Int, confirm: Bool) -> [UInt8] {
        let down: [UInt8] = [0x1b, 0x5b, 0x42]   // ESC [ B
        let space: UInt8 = 0x20
        let enter: UInt8 = 0x0d
        var out: [UInt8] = []
        guard count > 0 else { return out }
        for i in 0..<count {
            if wanted.contains(i) { out.append(space) }
            if i < count - 1 { out.append(contentsOf: down) }
        }
        if confirm && !wanted.isEmpty { out.append(enter) }
        return out
    }

    static let quit: [UInt8] = [0x71]  // 'q'

    /// Total item count from a "[current/total]" header. Mole caps how many
    /// rows it renders (≈50), so on a long list the header total exceeds the
    /// number we can parse — the UI uses this to say "showing N of M".
    static func totalCount(_ raw: String) -> Int? {
        let text = stripANSI(raw)
        guard let r = text.range(of: #"\[\d+/(\d+)\]"#, options: .regularExpression) else { return nil }
        let inside = text[r].dropFirst().dropLast()      // "1/53"
        return Int(inside.split(separator: "/").last.map(String.init) ?? "")
    }

    // MARK: - Parsing helpers

    private static func selectedCountIn(_ line: String) -> Int? {
        guard let r = line.range(of: #"(\d+)\s+selected"#, options: .regularExpression) else { return nil }
        return Int(line[r].split(separator: " ").first ?? "")
    }

    /// Parse one item row → (item, isCursorLine). Returns nil for non-item
    /// lines (header, footer, blanks).
    private static func parseItem(_ line: String) -> (MoTUIItem, Bool)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let markerIdx = trimmed.firstIndex(where: { $0 == checked || $0 == unchecked }) else { return nil }
        let isCursor = trimmed.first == cursorMark
        let selected = trimmed[markerIdx] == checked
        let rest = trimmed[trimmed.index(after: markerIdx)...].trimmingCharacters(in: .whitespaces)
        // rest: "Inkling-0.0.1.dmg                 771KB | Desktop"
        let pipeParts = rest.components(separatedBy: "|")
        let location = pipeParts.count > 1 ? pipeParts[1].trimmingCharacters(in: .whitespaces) : ""
        let left = pipeParts[0].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard left.count >= 2 else { return nil }
        let size = left.last!
        let name = left.dropLast().joined(separator: " ")
        guard !name.isEmpty else { return nil }
        return (MoTUIItem(name: name, size: size, location: location, selected: selected), isCursor)
    }

    /// Strip CSI escape sequences so the TUI's redraw control codes don't
    /// pollute parsing. (Mirror of CommandRunner.stripAnsi, kept local so
    /// this file is self-contained + testable.)
    static func stripANSI(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = String(); out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            if s[i] == "\u{1B}", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                var j = s.index(i, offsetBy: 2)
                while j < s.endIndex {
                    if let a = s[j].asciiValue, a >= 0x40, a <= 0x7E { j = s.index(after: j); break }
                    j = s.index(after: j)
                }
                i = j; continue
            }
            out.append(s[i]); i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Pseudo-terminal task

/// A child process attached to a pseudo-terminal, so a TUI program (Mole's
/// selection screen) believes it's interactive. Read/write the screen via
/// `master`. The only impure seam — kept tiny.
final class PTYTask {
    private let proc = Process()
    private(set) var master: FileHandle?

    var isRunning: Bool { proc.isRunning }
    var terminationStatus: Int32 { proc.terminationStatus }
    var onExit: (@Sendable () -> Void)?

    func launch(_ executable: String, _ args: [String], cols: UInt16 = 120, rows: UInt16 = 60) throws {
        var amaster: Int32 = 0
        var aslave: Int32 = 0
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&amaster, &aslave, nil, nil, &ws) == 0 else {
            throw NSError(domain: "burrow.pty", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "openpty failed"])
        }
        let slave = FileHandle(fileDescriptor: aslave, closeOnDealloc: false)
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = args
        proc.standardInput = slave
        proc.standardOutput = slave
        proc.standardError = slave
        var env = Foundation.ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        proc.environment = env
        proc.terminationHandler = { [weak self] _ in self?.onExit?() }
        master = FileHandle(fileDescriptor: amaster, closeOnDealloc: true)
        try proc.run()
        close(aslave)   // parent doesn't use the slave end
    }

    func send(_ bytes: [UInt8]) { try? master?.write(contentsOf: Data(bytes)) }
    func terminate() { if proc.isRunning { proc.terminate() } }
}
