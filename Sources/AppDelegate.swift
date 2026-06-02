//
//  AppDelegate.swift
//  Burrow
//
//  Wires the menu-bar item, kicks off the Mole sampler, starts the MCP
//  query server, runs hourly maintenance, and manages the History /
//  Cleanup / Settings windows.
//
//  Launch order (matters):
//
//    1. Verify `mo` is on PATH. Hard requirement — if missing, modal
//       alert with the install command, then quit.
//    2. Open the SQLite history DB at
//       `~/Library/Application Support/Burrow/burrow.db`.
//    3. Start QueryServer on 127.0.0.1:9277 (Store-controlled).
//    4. Start Sampler — spawns `mo status --json` at Store-configured
//       cadence.
//    5. Start Maintenance — hourly prune by retention.
//    6. Install the NSStatusItem.
//
//  Windows (history, cleanup, settings) are opened on demand from the
//  popover. Each has a single shared NSWindowController kept here so
//  reopening focuses the existing window instead of stacking.
//

import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Singleton handle so SwiftUI views (and the menu-bar popover)
    /// can reach the live Maintenance / Sampler / DB instances without
    /// passing them through every initializer. There is exactly one
    /// AppDelegate per app run; this is safe.
    static private(set) var shared: AppDelegate?

    private(set) var db: DB?
    private(set) var sampler: Sampler?
    private(set) var maintenance: Maintenance?
    private var queryServer: QueryServer?
    private var statusBar: StatusBarController?

    // Window controllers — one per kind, kept so reopen focuses.
    private var historyWC: NSWindowController?
    private var cleanupWC: NSWindowController?
    private var settingsWC: NSWindowController?
    private var diskMapWC: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // 1. Hard requirement.
        guard MoleCLI.findExecutable() != nil else {
            MoleCLI.showMissingAlert()
            NSApp.terminate(nil)
            return
        }

        // 2. DB.
        let db: DB
        do {
            db = try DB.openDefault()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't open Burrow's history database"
            alert.informativeText = "\(error.localizedDescription)\n\nThe app will quit."
            alert.alertStyle = .critical
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        self.db = db

        // 3. QueryServer (Store-gated).
        if Store.queryServerEnabled {
            let port = UInt16(clamping: Store.queryServerPort)
            self.queryServer = QueryServer(db: db, port: port)
            self.queryServer?.start()
        }

        // 4. Sampler.
        let sampler = Sampler(db: db,
                              intervalSeconds: TimeInterval(Store.sampleIntervalSeconds))
        self.sampler = sampler
        sampler.start()

        // 5. Maintenance.
        let maintenance = Maintenance(db: db)
        self.maintenance = maintenance
        maintenance.start()

        // 6. Status bar.
        self.statusBar = StatusBarController(db: db, sampler: sampler, delegate: self)
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.sampler?.stop()
        self.queryServer?.stop()
        self.maintenance?.stop()
    }

    // MARK: - Window openers

    /// Called by the popover. Each opener focuses an existing window
    /// if one is up, or builds a new one. The window controllers are
    /// retained on the delegate so they survive between opens.
    func openHistory() {
        if let wc = self.historyWC {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        guard let db = self.db else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 660),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Burrow History"
        window.center()
        window.isReleasedWhenClosed = false  // we manage lifetime via WC retain
        window.contentViewController = NSHostingController(rootView: HistoryView(db: db))

        let wc = NSWindowController(window: window)
        self.historyWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openCleanup() {
        if let wc = self.cleanupWC {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Burrow Cleanup"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: CleanupView())

        let wc = NSWindowController(window: window)
        self.cleanupWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openDiskMap() {
        if let wc = self.diskMapWC {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Burrow Disk Map"
        window.center()
        window.isReleasedWhenClosed = false
        // Treemap defaults to the user's home directory; the picker
        // inside the view lets them switch.
        window.contentViewController = NSHostingController(rootView: DiskMapView())

        let wc = NSWindowController(window: window)
        self.diskMapWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openSettings() {
        if let wc = self.settingsWC {
            wc.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        window.title = "Burrow Settings"
        window.center()
        window.isReleasedWhenClosed = false
        // SettingsView ties "Run maintenance now" to the live
        // Maintenance instance via this closure — no need to teach the
        // view about AppDelegate.shared.
        let view = SettingsView(onRunMaintenance: { [weak self] in
            self?.maintenance?.runNow()
        })
        window.contentViewController = NSHostingController(rootView: view)

        let wc = NSWindowController(window: window)
        self.settingsWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
