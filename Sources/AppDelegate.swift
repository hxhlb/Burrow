//
//  AppDelegate.swift
//  Burrow
//
//  Launch order (matters):
//
//    1. Verify `mo` is on PATH. Hard requirement — if missing, modal
//       alert with the install command, then quit.
//    2. Open the SQLite history DB.
//    3. Start QueryServer (Store-gated).
//    4. Start Sampler (Store-configured cadence).
//    5. Start Maintenance (hourly prune).
//    6. Install the NSStatusItem.
//
//  Windows: v0.3 collapsed the four separate windows (History,
//  DiskMap, Cleanup, Settings) into one main window with a sidebar.
//  `openMainWindow(initial:)` is the one entry point — the popover's
//  action buttons just deep-link by passing the section they want
//  selected.
//

import Cocoa
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// Singleton handle so SwiftUI views can reach the live
    /// Maintenance / Sampler / DB without threading them through every
    /// initializer.
    static private(set) var shared: AppDelegate?

    private(set) var db: DB?
    private(set) var sampler: Sampler?
    private(set) var maintenance: Maintenance?
    private var queryServer: QueryServer?
    private var statusBar: StatusBarController?

    /// Single main window. Holds the sidebar + content router. The
    /// `pendingInitialSection` is only used to pass the chosen tab
    /// across the window-creation boundary; cleared once the window's
    /// content view reads it.
    private var mainWC: NSWindowController?
    fileprivate var pendingInitialPane: Pane = .tool(.status)

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        guard MoleCLI.findExecutable() != nil else {
            MoleCLI.showMissingAlert()
            NSApp.terminate(nil)
            return
        }

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

        if Store.queryServerEnabled {
            let port = UInt16(clamping: Store.queryServerPort)
            self.queryServer = QueryServer(db: db, port: port)
            self.queryServer?.start()
        }

        let sampler = Sampler(db: db,
                              intervalSeconds: TimeInterval(Store.sampleIntervalSeconds))
        self.sampler = sampler
        sampler.start()

        let maintenance = Maintenance(db: db)
        self.maintenance = maintenance
        maintenance.start()

        self.statusBar = StatusBarController(db: db, sampler: sampler, delegate: self)

        // Dev affordance: launch with BURROW_OPEN_ON_LAUNCH=1 to pop the
        // main window straight away (used for screenshot/verify loops).
        if let tab = Foundation.ProcessInfo.processInfo.environment["BURROW_OPEN_ON_LAUNCH"],
           #available(macOS 14, *) {
            let pane: Pane = (tab == "settings") ? .settings : (tab == "history") ? .history
                : .tool(Tool(rawValue: tab) ?? .status)
            self.openMainWindow(initial: pane)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        self.sampler?.stop()
        self.queryServer?.stop()
        self.maintenance?.stop()
    }

    // MARK: - Window

    /// Open the main window, focusing the requested section. If the
    /// window already exists, just selects the section and brings the
    /// window forward. Used by every popover action button —
    /// `openMainWindow(initial: .cleanup)` etc.
    @available(macOS 14.0, *)
    func openMainWindow(initial: Pane = .tool(.status)) {
        // If already open, just switch to the requested pane and bring
        // the window forward.
        if let wc = self.mainWC, let window = wc.window {
            self.pendingInitialPane = initial
            self.installMainContent(into: window, initial: initial)
            NSApp.setActivationPolicy(.regular)   // Dock icon while open
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard self.db != nil, self.sampler != nil else { return }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        // Frameless-feeling translucent shell: transparent titlebar with
        // the traffic lights floating over content, a clear non-opaque
        // window so the behind-window vibrancy can sample the wallpaper,
        // and drag-anywhere so there's no visible chrome bar.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Burrow"
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 640)
        window.delegate = self

        // Show a Dock icon (and Cmd-Tab presence) while the dashboard is
        // open; we drop back to a pure menu-bar agent when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppDelegate.dockIcon

        let wc = NSWindowController(window: window)
        self.mainWC = wc
        self.installMainContent(into: window, initial: initial)
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @available(macOS 14.0, *)
    private func installMainContent(into window: NSWindow, initial: Pane) {
        guard let db = self.db, let sampler = self.sampler else { return }
        let root = RootView(db: db, sampler: sampler, delegate: self, initialPane: initial)
        let host = NSHostingController(rootView: root)
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = .clear
        window.contentViewController = host
    }

    // MARK: - Window delegate

    func windowWillClose(_ notification: Notification) {
        // Dashboard closed → back to a pure menu-bar agent (no Dock icon).
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Dock icon

    /// Burrow's mark drawn into an app icon: a cream disc with the dark
    /// burrow mouth on a rounded espresso tile. Programmatic for now so we
    /// don't need an asset-catalog AppIcon.
    static let dockIcon: NSImage = {
        let size = NSSize(width: 512, height: 512)
        let img = NSImage(size: size)
        img.lockFocus()
        let full = NSRect(origin: .zero, size: size)

        let tile = NSBezierPath(roundedRect: full.insetBy(dx: 26, dy: 26), xRadius: 110, yRadius: 110)
        NSColor(srgbRed: 0.14, green: 0.11, blue: 0.07, alpha: 1).setFill()
        tile.fill()

        let disc = full.insetBy(dx: 116, dy: 116)
        NSColor(srgbRed: 0.95, green: 0.92, blue: 0.86, alpha: 1).setFill()
        NSBezierPath(ovalIn: disc).fill()

        let cx = full.midX
        let baseY = full.height * 0.44
        let r = full.width * 0.17
        let dome = NSBezierPath()
        dome.move(to: NSPoint(x: cx - r, y: baseY))
        dome.appendArc(withCenter: NSPoint(x: cx, y: baseY), radius: r,
                       startAngle: 180, endAngle: 0, clockwise: true)
        dome.close()
        NSColor(srgbRed: 0.14, green: 0.11, blue: 0.07, alpha: 1).setFill()
        dome.fill()

        img.unlockFocus()
        return img
    }()
}
