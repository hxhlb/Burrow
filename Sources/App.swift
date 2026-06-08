//
//  App.swift
//  Burrow
//
//  Entry point with a process-mode fork:
//
//    * `Burrow`        → menu-bar GUI (default).
//    * `Burrow --mcp`  → stdio JSON-RPC MCP server for Claude Code.
//    * `burrow mcp`    → same, via the Homebrew PATH shim (no .app path).
//
//  Pure AppKit bootstrap (no SwiftUI `App`/`Settings` scene). The old
//  `Settings { EmptyView() }` scene auto-bound ⌘, to a blank window —
//  the "fake settings window". Now ⌘, is a real menu command that opens
//  the Settings *pane* inside the main window (see AppDelegate's menu).
//  Windows are managed imperatively by AppDelegate so they can be driven
//  from the status-bar HUD.
//

import AppKit

@main
enum BurrowMain {
    /// Strong reference — NSApplication.delegate is weak.
    private static var delegate: AppDelegate?

    /// Whether this launch should run the stdio MCP server instead of the
    /// GUI. Accepts the original `--mcp` flag and the `burrow mcp`
    /// subcommand form the PATH shim uses. Pure so it's unit-testable.
    static func isMCPInvocation(_ args: [String]) -> Bool {
        if args.contains("--mcp") { return true }
        return args.dropFirst().first == "mcp"
    }

    static func main() {
        if isMCPInvocation(CommandLine.arguments) {
            FileHandle.standardError.write(Data("burrow.main: stdio MCP mode\n".utf8))
            MCP.runStdioLoop()
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        BurrowMain.delegate = delegate
        app.delegate = delegate
        // Start as a menu-bar agent; AppDelegate flips to .regular while a
        // window is open so the Dock icon + menu bar appear.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
