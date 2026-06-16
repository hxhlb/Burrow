//
//  StatusBarController.swift
//  Burrow
//
//  Owns the NSStatusItem and its popover. The popover is created
//  lazily on first click and reused; its NSHostingController holds
//  the SwiftUI `PopupView` bound to the LiveFeed (for live snapshot
//  data) and the AppDelegate (for the History / Cleanup / Settings
//  buttons that open windows).
//
//  Icon: `chart.line.uptrend.xyaxis`. Reads as "this thing tracks
//  something over time" — semantically aligned with what Burrow does.
//  Template image so it adapts to light/dark menu bars.
//

import AppKit
import SwiftUI
import Combine

final class StatusBarController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private let popover: NSPopover
    private let db: DB
    private let producer: SnapshotProducer
    private weak var delegate: AppDelegate?
    private var metricsSub: AnyCancellable?
    /// 1 Hz net/disk-rate updates for the metrics row (separate from the
    /// snapshot sink so live throughput animates between snapshots).
    private var samplesSub: AnyCancellable?
    /// Rolling per-metric history for the menu-bar sparkline style, appended
    /// at the snapshot cadence (net/disk sparklines read straight off the
    /// live ring instead).
    private var menuBarHistory: [MenuBarMetric: [Double]] = [:]
    /// A small accent dot shown over the glyph when a Burrow self-update is
    /// available (driven by AppUpdate via .burrowUpdateAvailability).
    private let updateDot = NSView()
    private var updateObserver: NSObjectProtocol?
    /// Driven by the .burrowUpdateAvailability payload — avoids reading the
    /// @MainActor AppUpdate singleton from this (nonisolated) controller.
    private var updateAvailable = false

    init(db: DB, producer: SnapshotProducer, delegate: AppDelegate) {
        self.db = db
        self.producer = producer
        self.delegate = delegate
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        // Build the popover before the button-target line below so all
        // `let` properties are initialized when `self` first leaks via
        // the @objc selector dispatch.
        let popover = NSPopover()
        popover.behavior = .transient
        // Dark to match the app's glass aesthetic (affects the popover
        // chrome + arrow; the HUD content paints its own dark surface).
        popover.appearance = NSAppearance(named: .darkAqua)
        // Initial size hint for the first measurement pass; HUDController
        // then drives the real (screen-capped) size via preferredContentSize.
        popover.contentSize = NSSize(width: 334, height: 560)
        popover.contentViewController = HUDController(
            root: PopupView(db: db, live: producer.live, feeds: delegate.feeds, delegate: delegate))
        self.popover = popover

        super.init()

        if let button = self.item.button {
            // Burrow's own mark as a template glyph (adapts to the menu bar).
            button.image = BurrowIcons.menuBar
            button.action = #selector(self.handleClick(_:))
            button.target = self
            // Right-click gets the quick menu; left-click keeps the HUD.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

            updateDot.wantsLayer = true
            updateDot.layer?.backgroundColor = NSColor(Tool.status.accent).cgColor
            updateDot.layer?.cornerRadius = 3
            updateDot.frame = NSRect(x: 0, y: 0, width: 6, height: 6)
            button.addSubview(updateDot)
        }
        applyDisplayMode()
        refreshUpdateDot()
        updateObserver = NotificationCenter.default.addObserver(
            forName: .burrowUpdateAvailability, object: nil, queue: .main) { [weak self] note in
            self?.updateAvailable = (note.object as? Bool) ?? false
            self?.refreshUpdateDot()
        }
    }

    /// Show/hide + reposition the update dot at the glyph's top-right.
    func refreshUpdateDot() {
        updateDot.isHidden = !updateAvailable
        if let b = item.button?.bounds {
            updateDot.frame.origin = CGPoint(x: max(2, b.maxX - 8), y: b.maxY - 8)
        }
    }

    /// Icon vs Metrics (Settings ▸ Menu Bar). Metrics renders the user's
    /// configured `Store.menuBarItems` row (issue #82); icon shows the mark.
    /// Safe to call again to apply a settings change live.
    func applyDisplayMode() {
        guard let button = item.button else { return }
        guard Store.menuBarDisplayMode == .metrics else {
            metricsSub = nil
            samplesSub = nil
            menuBarHistory.removeAll()
            button.image = BurrowIcons.menuBar
            button.imagePosition = .imageOnly
            button.title = ""
            refreshUpdateDot()
            return
        }
        // Snapshot sink: CPU/RAM/GPU/disk/fan/temp/battery + sparkline history.
        metricsSub = producer.live.$lastSnapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onSnapshot() }
        // 1 Hz sink: live net/disk rates + their sparklines.
        samplesSub = producer.live.$samples
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderMetrics() }
        renderMetrics()
        refreshUpdateDot()
    }

    /// Snapshot tick: extend the cpu/mem/gpu sparkline rings (only the snapshot
    /// carries those series), then redraw.
    private func onSnapshot() {
        guard Store.menuBarDisplayMode == .metrics, let s = producer.live.lastSnapshot else { return }
        appendHistory(.cpu, s.cpu.usage)
        appendHistory(.memory, s.memory.usedPercent)
        if let g = s.gpu?.first, g.usage >= 0 { appendHistory(.gpu, g.usage) }
        renderMetrics()
    }

    private func appendHistory(_ m: MenuBarMetric, _ v: Double) {
        var ring = menuBarHistory[m] ?? []
        ring.append(v)
        if ring.count > 40 { ring.removeFirst(ring.count - 40) }
        menuBarHistory[m] = ring
    }

    /// Assemble the current values and draw the row into the status button.
    /// Deliberately cheap (a few strings + shapes) and reads only already-
    /// published live values — never the running-app list or other blocking
    /// work, so the menu bar can't add to the main-thread budget.
    private func renderMetrics() {
        guard let button = item.button, Store.menuBarDisplayMode == .metrics else { return }
        if let image = MenuBarRenderer.image(items: Store.menuBarItems, values: currentValues()) {
            button.image = image
        } else {
            button.image = BurrowIcons.menuBar
        }
        button.imagePosition = .imageOnly
        button.title = ""
        refreshUpdateDot()
    }

    /// Snapshot of every metric the row might draw, read on the main thread
    /// from the live feed (which is itself main-thread-confined).
    private func currentValues() -> MenuBarMetricValues {
        var v = MenuBarMetricValues()
        let live = producer.live
        if let s = live.lastSnapshot {
            v.primary[.cpu] = s.cpu.usage
            v.primary[.memory] = s.memory.usedPercent
            if let g = s.gpu?.first, g.usage >= 0 { v.primary[.gpu] = g.usage }
            if let d = s.disks.first { v.primary[.diskUsage] = d.usedPercent }
            if let t = s.thermal {
                if t.fanSpeed > 0 || (t.fanCount ?? 0) > 0 { v.primary[.fan] = Double(t.fanSpeed) }
                if let temp = t.bestTemp { v.primary[.temperature] = temp }
            }
            if let b = s.batteries?.first {
                v.primary[.battery] = b.percent
                v.batteryCharging = b.status.lowercased().contains("charg")
            }
        }
        v.primary[.network] = live.rxMBs;   v.secondary[.network] = live.txMBs
        v.primary[.diskIO]  = live.readMBs;  v.secondary[.diskIO]  = live.writeMBs
        let recent = live.samples.suffix(30)
        v.histories[.network] = recent.map { $0.rxMBs + $0.txMBs }
        v.histories[.diskIO]  = recent.map { $0.readMBs + $0.writeMBs }
        v.histories[.cpu]    = menuBarHistory[.cpu]
        v.histories[.memory] = menuBarHistory[.memory]
        v.histories[.gpu]    = menuBarHistory[.gpu]
        return v
    }

    deinit {
        if let o = updateObserver { NotificationCenter.default.removeObserver(o) }
        // Explicitly remove the item so toggling the menu-bar setting off
        // (AppDelegate drops its reference) clears it from the bar at once.
        NSStatusBar.system.removeStatusItem(item)
    }

    @objc private func handleClick(_ sender: Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showQuickMenu()
            return
        }
        guard let button = self.item.button else { return }
        if self.popover.isShown {
            self.popover.performClose(sender)
        } else {
            self.popover.show(relativeTo: button.bounds,
                              of: button,
                              preferredEdge: .minY)
            // Pull focus so the popover's keyboard shortcuts (⌘Q etc.)
            // are reachable without a second click.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Right-click quick menu

    private func showQuickMenu() {
        let menu = NSMenu()
        menu.delegate = self

        menu.addItem(makeItem(NSLocalizedString("Open Burrow", comment: ""),
                              action: #selector(openBurrow)))
        menu.addItem(makeItem(NSLocalizedString("Settings…", comment: ""),
                              action: #selector(openSettings), key: ","))
        menu.addItem(.separator())

        // Keep Screen On ▸ durations, with a checkmark while active.
        let awakeItem = NSMenuItem(title: NSLocalizedString("Keep Screen On", comment: ""),
                                   action: nil, keyEquivalent: "")
        awakeItem.state = Awake.shared.isActive ? .on : .off
        let awakeMenu = NSMenu()
        for duration in Awake.Duration.allCases {
            let di = NSMenuItem(title: duration.label, action: #selector(startAwake(_:)), keyEquivalent: "")
            di.target = self
            di.representedObject = duration
            awakeMenu.addItem(di)
        }
        if Awake.shared.isActive {
            awakeMenu.addItem(.separator())
            awakeMenu.addItem(makeItem(NSLocalizedString("Turn Off", comment: ""), action: #selector(stopAwake)))
        }
        awakeItem.submenu = awakeMenu
        menu.addItem(awakeItem)

        let cleanItem = makeItem(NSLocalizedString("Clean Screen", comment: ""), action: #selector(cleanScreen))
        cleanItem.state = CleanScreen.shared.isActive ? .on : .off
        menu.addItem(cleanItem)
        menu.addItem(.separator())
        menu.addItem(makeItem(NSLocalizedString("About Burrow", comment: ""), action: #selector(showAbout)))
        menu.addItem(makeItem(NSLocalizedString("Check for Updates…", comment: ""), action: #selector(checkUpdates)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: NSLocalizedString("Quit Burrow", comment: ""),
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)

        // Pop the menu without permanently assigning it (which would
        // hijack left-clicks too).
        item.menu = menu
        item.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        item.menu = nil
    }

    private func makeItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func openBurrow() {
        if #available(macOS 14, *) { delegate?.openMainWindow(initial: .home) }
    }
    @objc private func openSettings() {
        if #available(macOS 14, *) { delegate?.openMainWindow(initial: .settings) }
    }
    @objc private func startAwake(_ sender: NSMenuItem) {
        guard let duration = sender.representedObject as? Awake.Duration else { return }
        Awake.shared.start(duration)
    }
    @objc private func stopAwake() { Awake.shared.stop() }
    @objc private func cleanScreen() { CleanScreen.shared.toggle() }
    @objc private func showAbout() { delegate?.showAboutPanel() }
    @objc private func checkUpdates() { UpdateCheck.checkNow() }
}
