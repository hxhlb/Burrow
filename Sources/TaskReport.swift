//
//  TaskReport.swift
//  Burrow
//
//  Shared engine for the two "run a mo job and show the result" tabs —
//  Clean and Optimize. Both emit the same shape of human output:
//
//      ➤ Category
//        → did a thing, 191.3MB
//        ✓ nothing to do
//        • review-only item
//      Potential space: 383.8MB | Items: 372 | Categories: 20
//
//  CommandRunner streams a `mo` subcommand line-by-line; parseTaskReport
//  turns those lines into themed cards; ToolHero / HeroOrb / PillButton
//  are the shared idle-state chrome.
//

import SwiftUI
import AppKit

// MARK: - Parsed model

enum TaskMarker {
    case action, ok, review, error, info
    init(_ c: Character) {
        switch c {
        case "→", "➜":      self = .action
        case "✓", "✔":      self = .ok
        case "•", "◎", "●": self = .review
        case "✗", "✘", "✕": self = .error
        default:            self = .info
        }
    }
}

struct TaskItem: Identifiable {
    let id = UUID()
    let marker: TaskMarker
    let text: String
}

struct TaskGroup: Identifiable {
    let id = UUID()
    let title: String
    var items: [TaskItem]
}

struct TaskSummary {
    let space: String      // "383.8MB"
    let items: String      // "372"
    let categories: String // "20"
}

func parseTaskReport(_ lines: [String]) -> (groups: [TaskGroup], summary: TaskSummary?) {
    var groups: [TaskGroup] = []
    var summary: TaskSummary?
    let markerChars: Set<Character> = ["→", "➜", "✓", "✔", "•", "◎", "●", "✗", "✘", "✕"]

    for raw in lines {
        let t = raw.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("↳") { continue }

        if t.hasPrefix("➤") {
            let title = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            groups.append(TaskGroup(title: title, items: []))
        } else if let first = t.first, markerChars.contains(first) {
            let text = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
            if groups.isEmpty { groups.append(TaskGroup(title: "Summary", items: [])) }
            groups[groups.count - 1].items.append(TaskItem(marker: TaskMarker(first), text: text))
        } else if t.hasPrefix("Potential space:") {
            summary = parseSummary(t)
        } else if t == t.uppercased(), t.count > 4, t.count < 40, !t.contains(":"), !t.contains("|") {
            groups.append(TaskGroup(title: t.capitalized, items: []))
        }
    }
    return (groups.filter { !$0.items.isEmpty }, summary)
}

private func parseSummary(_ line: String) -> TaskSummary {
    var space = "", items = "", cats = ""
    for part in line.components(separatedBy: "|") {
        let kv = part.components(separatedBy: ":")
        guard kv.count >= 2 else { continue }
        let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
        let val = kv[1].trimmingCharacters(in: .whitespaces)
        if key.contains("space") { space = val }
        else if key.contains("item") { items = val }
        else if key.contains("categor") { cats = val }
    }
    return TaskSummary(space: space, items: items, categories: cats)
}

// MARK: - Streaming runner

@MainActor
final class CommandRunner: ObservableObject {
    enum Phase: Equatable { case idle, running, done(Int32), failed(String) }

    @Published var phase: Phase = .idle
    @Published var lines: [String] = []
    /// Parsed report, recomputed once per coalesced flush — NOT per SwiftUI
    /// render. Views read these instead of re-parsing `lines` every frame.
    @Published private(set) var groups: [TaskGroup] = []
    @Published private(set) var summary: TaskSummary?
    /// Set when the user aborts via `cancel()`, so the UI can say "Stopped"
    /// rather than reporting the terminated process as a plain failure.
    @Published private(set) var wasCancelled = false

    let opId = UUID()
    private var operationLabel: String?
    private var task: Process?
    private var buffer = ""
    private var pending: [String] = []
    private var flushScheduled = false
    private var tailTimer: Timer?
    private var logHandle: FileHandle?

    func run(_ args: [String], elevated: Bool = false, label: String? = nil) {
        guard let mo = MoleCLI.findExecutable() else { phase = .failed("mo not found"); return }
        lines = []; buffer = ""; pending = []; groups = []; summary = nil; wasCancelled = false; phase = .running
        operationLabel = label
        if let label { OperationCenter.shared.begin(opId, label: label) }
        if elevated { runElevated(mo: mo, args: args); return }

        let t = Process()
        t.executableURL = URL(fileURLWithPath: mo)
        t.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        t.standardOutput = outPipe
        t.standardError = errPipe

        let handler: @Sendable (FileHandle) -> Void = { h in
            let d = h.availableData
            guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
            let stripped = CommandRunner.stripAnsi(s)
            DispatchQueue.main.async { self.ingest(stripped) }
        }
        outPipe.fileHandleForReading.readabilityHandler = handler
        errPipe.fileHandleForReading.readabilityHandler = handler

        t.terminationHandler = { proc in
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                self.flush()
                self.phase = .done(proc.terminationStatus)
                if self.operationLabel != nil {
                    OperationCenter.shared.end(self.opId, success: proc.terminationStatus == 0)
                }
            }
        }
        do { try t.run(); task = t }
        catch { phase = .failed(error.localizedDescription) }
    }

    func cancel() {
        wasCancelled = true
        if let t = task, t.isRunning { t.terminate() }
        tailTimer?.invalidate(); tailTimer = nil
        // If the process already exited (or never streamed), settle the UI
        // immediately rather than waiting on a terminationHandler that may
        // not fire for an already-dead task.
        if task == nil || task?.isRunning == false { phase = .done(130) }
    }

    /// Return to the idle (hero) state — used by the "Back" button on a
    /// finished report so the user can get back to the tool's menu.
    func reset() {
        phase = .idle
        lines = []; buffer = ""; pending = []; groups = []; summary = nil; wasCancelled = false
    }

    /// Run `mo <args>` as root via ONE osascript auth prompt, instead of
    /// `mo` prompting per privileged step (which produced several password
    /// dialogs for a single clean). `do shell script` doesn't stream, so we
    /// redirect output to a temp log and tail it for live updates.
    private func runElevated(mo: String, args: [String]) {
        let safe = args.map { $0.filter(\.isLetter) }.joined(separator: "-")
        let logPath = NSTemporaryDirectory() + "burrow-op-\(safe).log"
        FileManager.default.createFile(atPath: logPath, contents: Data())
        let inner = "\(mo) \(args.joined(separator: " ")) > '\(logPath)' 2>&1"
        let script = "do shell script \"\(inner)\" with administrator privileges"

        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", script]
        t.standardOutput = Pipe()
        t.standardError = Pipe()

        self.logHandle = FileHandle(forReadingAtPath: logPath)
        self.tailTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.drainLog() }
        }
        t.terminationHandler = { proc in
            Task { @MainActor in
                self.drainLog()
                self.tailTimer?.invalidate(); self.tailTimer = nil
                try? self.logHandle?.close(); self.logHandle = nil
                self.phase = (proc.terminationStatus != 0 && self.lines.isEmpty)
                    ? .failed("authorization cancelled") : .done(proc.terminationStatus)
                if self.operationLabel != nil {
                    OperationCenter.shared.end(self.opId, success: proc.terminationStatus == 0)
                }
            }
        }
        do { try t.run(); task = t }
        catch { phase = .failed(error.localizedDescription) }
    }

    private func drainLog() {
        guard let h = logHandle else { return }
        let data = h.readDataToEndOfFile()
        guard !data.isEmpty, let s = String(data: data, encoding: .utf8) else { return }
        ingest(CommandRunner.stripAnsi(s))
    }

    private func ingest(_ s: String) {
        buffer += s
        var parts = buffer.components(separatedBy: "\n")
        buffer = parts.removeLast()
        guard !parts.isEmpty else { return }
        pending.append(contentsOf: parts)
        if operationLabel != nil, let last = parts.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            OperationCenter.shared.detail(opId, last)
        }
        scheduleFlush()
    }

    /// Coalesce output: batch incoming lines and update @Published state at
    /// most ~8×/sec, so a chatty `mo` run doesn't re-render the report (and
    /// re-parse every line) on each chunk — the GUI overhead that made the
    /// app feel heavier and laggier than the bare CLI.
    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.applyPending() }
    }

    private func applyPending() {
        flushScheduled = false
        guard !pending.isEmpty else { return }
        lines.append(contentsOf: pending)
        pending.removeAll(keepingCapacity: true)
        let r = parseTaskReport(lines)
        groups = r.groups; summary = r.summary
    }

    /// Final flush at end of stream (plus the trailing partial line).
    private func flush() {
        if !buffer.isEmpty { pending.append(buffer); buffer = "" }
        applyPending()
    }

    nonisolated static func stripAnsi(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = String()
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            if c == "\u{1B}", s.index(after: i) < s.endIndex, s[s.index(after: i)] == "[" {
                var j = s.index(i, offsetBy: 2)
                while j < s.endIndex {
                    if let a = s[j].asciiValue, a >= 0x40, a <= 0x7E { j = s.index(after: j); break }
                    j = s.index(after: j)
                }
                i = j; continue
            }
            out.append(c); i = s.index(after: i)
        }
        return out
    }
}

// MARK: - Report view

struct TaskReportView: View {
    let groups: [TaskGroup]
    let accent: Color

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        GlassCard {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(group.title.uppercased())
                                    .font(Brand.mono(10, .bold)).tracking(0.7)
                                    .foregroundStyle(accent)
                                ForEach(Array(group.items.enumerated()), id: \.offset) { _, item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        marker(item.marker)
                                        Text(item.text)
                                            .font(Brand.sans(12))
                                            .foregroundStyle(textColor(item.marker))
                                            .fixedSize(horizontal: false, vertical: true)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("BOTTOM")
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
            // Tail-follow the report as new lines stream in.
            .onChange(of: itemCount) { _, _ in
                withAnimation(.linear(duration: 0.15)) { proxy.scrollTo("BOTTOM", anchor: .bottom) }
            }
        }
    }

    private var itemCount: Int { groups.reduce(0) { $0 + $1.items.count } }

    @ViewBuilder
    private func marker(_ m: TaskMarker) -> some View {
        switch m {
        case .action: Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(accent)
        case .ok:     Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.green)
        case .review: Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9)).foregroundStyle(Brand.gold)
        case .error:  Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.red)
        case .info:   Image(systemName: "minus").font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.textTertiary)
        }
    }
    private func textColor(_ m: TaskMarker) -> Color {
        switch m {
        case .ok, .info: return Brand.textSecondary
        default:         return Brand.textPrimary
        }
    }
}

// MARK: - Shared idle chrome

struct HeroOrb: View {
    let accent: Color
    var size: CGFloat = 150
    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(
                colors: [accent.opacity(0.85), accent.opacity(0.12)],
                center: .init(x: 0.4, y: 0.35), startRadius: 4, endRadius: size * 0.85))
            Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .frame(width: size, height: size)
        .shadow(color: accent.opacity(0.35), radius: 40)
    }
}

struct PillButton: View {
    let title: String
    var filled: Bool = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Brand.sans(13, .semibold))
                .foregroundStyle(filled ? Color.black : Brand.textPrimary)
                .padding(.horizontal, 22).padding(.vertical, 10)
                .background(Capsule().fill(filled ? Color.white : Color.white.opacity(0.08)))
                .overlay(filled ? nil : Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

struct ToolHero<Buttons: View>: View {
    let tool: Tool
    let title: String
    let subtitle: String
    @ViewBuilder var buttons: () -> Buttons
    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            HeroOrb(accent: tool.accent)
            VStack(spacing: 8) {
                Text(title).font(Brand.serif(28, .medium)).foregroundStyle(Brand.textPrimary)
                Text(subtitle).font(Brand.serif(15)).italic().foregroundStyle(Brand.textSecondary)
            }
            HStack(spacing: 12) { buttons() }.padding(.top, 4)
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Success header shown above a finished Clean / Optimize report.
struct DoneBanner: View {
    let accent: Color
    let title: String
    var detail: String? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.18)).frame(width: 38, height: 38)
                Image(systemName: "checkmark").font(.system(size: 16, weight: .bold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Brand.sans(15, .semibold)).foregroundStyle(Brand.textPrimary)
                if let d = detail { Text(d).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary) }
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(accent.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(accent.opacity(0.35), lineWidth: 1))
        .padding(.horizontal, 18).padding(.top, 8)
    }
}
