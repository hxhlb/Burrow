//
//  MoleCLI.swift
//  Burrow
//
//  Wrapper around the `mo` command. Burrow doesn't ship Mole — it depends
//  on a system-installed copy (`brew install mole`), found via PATH.
//
//  Three commands matter to Burrow today:
//    * `mo status --json` — periodic sampler (Sampler.swift uses this).
//      Emits the full system snapshot as JSON in ~3 KB. Auto-emits JSON
//      when stdout is not a TTY, but we pass `--json` explicitly so the
//      contract is visible in the args.
//    * `mo clean` / `mo optimize` — CleanView / OptimizeView (streamed).
//    * `mo analyze --json` — Analyze treemap (DiskScanner).
//    * `mo uninstall --list` — Software tab app list (JSON).
//
//  Everything routes through `run(args:)` so subprocess plumbing
//  (timeout, env, NSPipe management) lives in one place.
//

import Foundation
import AppKit  // NSAlert

enum MoleCLI {
    /// Locate the `mo` executable. Checks PATH plus a few known install
    /// locations because GUI apps inherit a stripped-down PATH that often
    /// doesn't include Homebrew's bin directory.
    static func findExecutable() -> String? {
        // Hardcoded fallbacks first — fastest path and works in the GUI-launched
        // case where PATH is `/usr/bin:/bin:/usr/sbin:/sbin` and Homebrew is
        // invisible.
        let candidates = [
            "/opt/homebrew/bin/mo",      // Apple Silicon Homebrew
            "/usr/local/bin/mo",          // Intel Homebrew / manual install
            "/usr/bin/mo",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Last resort: ask the shell. Will work if the user launched Burrow
        // from a terminal with their PATH set up, but not from Finder.
        if let viaShell = try? run(args: ["which", "mo"], executable: "/usr/bin/env").stdout,
           let first = viaShell.split(separator: "\n").first {
            let trimmed = String(first).trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, FileManager.default.isExecutableFile(atPath: trimmed) {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Install / version

    /// Canonical install command (Homebrew). Shown in the guided install
    /// flow; we never run it for the user.
    static let installCommand = "brew install mole"
    /// Where to send users without Homebrew.
    static let repoURL = URL(string: "https://github.com/tw93/Mole")!

    /// Current `mo` version, or nil if not installed / unparsable.
    static func version() -> String? {
        guard let res = try? run(args: ["--version"], timeout: 5) else { return nil }
        let text = res.stdout.isEmpty ? res.stderr : res.stdout
        return parseVersion(text)
    }

    /// Pull a semver out of `mo --version` output, whatever decoration it
    /// wraps it in ("mole 1.41.0", "v1.41.0", …). Pure → unit-tested.
    static func parseVersion(_ output: String) -> String? {
        for token in output.split(whereSeparator: { !($0.isNumber || $0 == ".") }) {
            let parts = token.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ Int($0) != nil }) {
                return String(token)
            }
        }
        return nil
    }

    /// Modal alert shown at launch when `mo` isn't installed. We block on
    /// it because there's nothing useful Burrow can do without Mole, and a
    /// background app silently failing is the worst possible UX for this
    /// dependency model.
    static func showMissingAlert() {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Mole CLI not found", comment: "")
        alert.informativeText = NSLocalizedString("""
            Burrow uses the Mole CLI (`mo`) for system metrics and cleanup. \
            Install it with:

                brew install mole

            Then relaunch Burrow.
            """, comment: "")
        alert.alertStyle = .critical
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        _ = alert.runModal()
    }

    /// Result of a subprocess invocation. `exitCode == 0` is the success
    /// convention; callers that care about diagnostics should look at
    /// `stderr` when it's non-zero.
    struct Result {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    /// Run an executable with the given args, capturing stdout + stderr.
    /// Blocks until the process exits — callers are responsible for
    /// running this on a background queue. Times out after `timeout`
    /// seconds; on timeout the process is terminated and we throw, rather
    /// than returning a partial result, because callers always want
    /// either a complete snapshot or to retry.
    @discardableResult
    static func run(args: [String],
                    executable: String? = nil,
                    timeout: TimeInterval = 10) throws -> Result {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable ?? (findExecutable() ?? "/usr/bin/false"))
        task.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe

        try task.run()

        // Kill the task after `timeout` if it's still running. The
        // termination handler clears the timer so we don't fire stale
        // kills against a recycled PID.
        let killer = DispatchWorkItem { [weak task] in
            if let task, task.isRunning { task.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: killer)

        task.waitUntilExit()
        killer.cancel()

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        return Result(
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? "",
            exitCode: task.terminationStatus
        )
    }
}
