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

    private var installWC: NSWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        // No engine yet → guided install instead of a dead-end quit. The
        // window's Recheck calls startServices() once `mo` is found.
        guard MoleCLI.findExecutable() != nil else {
            showInstallWindow()
            return
        }
        startServices()
    }

    /// Guided onboarding window when `mo` is missing. Stays a regular Dock
    /// app so the window is reachable; we never run an installer ourselves.
    private func showInstallWindow() {
        NSApp.setActivationPolicy(.regular)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.center()
        let view = MoleInstallView(onReady: { [weak self] in
            self?.installWC?.close()
            self?.installWC = nil
            self?.startServices()
        })
        window.contentViewController = NSHostingController(rootView: view)
        let wc = NSWindowController(window: window)
        self.installWC = wc
        wc.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The `mo`-dependent startup: open the DB, start the server/sampler/
    /// maintenance, and install the status item. Called either directly at
    /// launch or after the guided install finds `mo`.
    private func startServices() {
        let db: DB
        do {
            db = try DB.openDefault()
        } catch {
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Couldn't open Burrow's history database", comment: "")
            alert.informativeText = String(format: NSLocalizedString("%@\n\nThe app will quit.", comment: ""),
                                           error.localizedDescription)
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
        self.setupMainMenu()

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
        window.title = NSLocalizedString("Burrow", comment: "")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 940, height: 640)
        window.delegate = self

        // Show a Dock icon (and Cmd-Tab presence) while the dashboard is
        // open; we drop back to a pure menu-bar agent when it closes. The
        // icon itself comes from Assets.xcassets/AppIcon.
        NSApp.setActivationPolicy(.regular)

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

    // MARK: - Main menu

    /// Minimal AppKit main menu — shows when the app is active (.regular,
    /// i.e. a window open). Gives a real ⌘, (Settings pane), proper Quit,
    /// and an Edit menu so text fields get cut/copy/paste/select-all.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: NSLocalizedString("About Burrow", comment: ""),
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: NSLocalizedString("Settings…", comment: ""),
                                  action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: NSLocalizedString("Hide Burrow", comment: ""), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: NSLocalizedString("Quit Burrow", comment: ""), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu (text editing in search fields etc.)
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: NSLocalizedString("Edit", comment: ""))
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: NSLocalizedString("Undo", comment: ""), action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: NSLocalizedString("Redo", comment: ""), action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: NSLocalizedString("Cut", comment: ""), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: NSLocalizedString("Copy", comment: ""), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: NSLocalizedString("Paste", comment: ""), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: NSLocalizedString("Select All", comment: ""), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        // Window menu
        let winItem = NSMenuItem()
        mainMenu.addItem(winItem)
        let winMenu = NSMenu(title: NSLocalizedString("Window", comment: ""))
        winItem.submenu = winMenu
        winMenu.addItem(withTitle: NSLocalizedString("Minimize", comment: ""), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: NSLocalizedString("Close", comment: ""), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = winMenu
    }

    @objc private func openSettingsFromMenu() {
        if #available(macOS 14, *) { openMainWindow(initial: .settings) }
    }
}
