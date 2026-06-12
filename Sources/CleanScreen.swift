//
//  CleanScreen.swift
//  Burrow
//
//  "Clean Screen": a borderless solid-color window per display at
//  screensaver level so you can wipe the glass without clicking things.
//  Esc exits, always. Swallowing OTHER keys while wiping is opt-in and
//  needs the Accessibility permission (a CGEventTap) — without it Clean
//  Screen still works, keys just aren't blocked. No artwork, one line of
//  our own copy.
//

import AppKit
import SwiftUI

final class CleanScreen: ObservableObject {
    static let shared = CleanScreen()

    private var windows: [NSWindow] = []
    private var eventTap: CFMachPort?
    private var localMonitor: Any?

    /// Published so the HUD's Wipe quick action can render an armed state
    /// (accent + "esc to exit") while the wipe overlay is up, the same way
    /// Stay Awake reflects `Awake.isActive`. Always mutated on the main
    /// thread (button actions, menu items, hot keys, the Esc monitor).
    @Published private(set) var isActive = false

    private init() {}

    func show() {
        guard windows.isEmpty else { return }
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.ignoresMouseEvents = false
            window.acceptsMouseMovedEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentViewController = NSHostingController(rootView: CleanScreenHint())
            window.makeKeyAndOrderFront(nil)
            windows.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Esc always exits via a local monitor (no permission needed).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide(); return nil }   // Esc
            return event
        }
        if Store.cleanScreenInputLock { startInputLock() }
        NSCursor.hide()
        isActive = true
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        stopInputLock()
        NSCursor.unhide()
        isActive = false
    }

    func toggle() { isActive ? hide() : show() }

    // MARK: - Opt-in input lock (Accessibility permission)

    /// Whether macOS lets us install the key-swallowing tap right now.
    static func inputLockPermitted() -> Bool {
        AXIsProcessTrusted()
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    private func startInputLock() {
        guard Self.inputLockPermitted(), eventTap == nil else { return }
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
        // Swallow everything except Esc (the exit key, handled above).
        eventTap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                     place: .headInsertEventTap,
                                     options: .defaultTap,
                                     eventsOfInterest: mask,
                                     callback: { _, type, event, _ in
                                         if type == .keyDown || type == .keyUp {
                                             let code = event.getIntegerValueField(.keyboardEventKeycode)
                                             if code == 53 { return Unmanaged.passUnretained(event) }
                                         }
                                         return nil
                                     },
                                     userInfo: nil)
        if let tap = eventTap {
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    private func stopInputLock() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
    }
}

private struct CleanScreenHint: View {
    @State private var showHint = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                Text("Wipe away — press Esc when you're done.")
                    .font(Brand.mono(12)).foregroundStyle(Color.white.opacity(showHint ? 0.45 : 0))
                    .padding(.bottom, 48)
            }
        }
        .onAppear {
            // The hint fades in after a beat so the screen starts clean.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                withAnimation(.easeIn(duration: 0.8)) { showHint = true }
            }
        }
    }
}
