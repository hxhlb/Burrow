//
//  HotKey.swift
//  Burrow
//
//  A recorded global shortcut (open/toggle Burrow) and the Carbon
//  RegisterEventHotKey plumbing that makes it system-wide. Deliberately
//  minimal — no third-party deps: one hot key, re-registered whenever
//  the recorded value changes.
//

import Foundation
import Carbon.HIToolbox
import AppKit

/// A key + modifier combination, storage- and display-friendly.
struct HotKey: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: UInt32
        static let control = Modifiers(rawValue: 1 << 0)
        static let option  = Modifiers(rawValue: 1 << 1)
        static let shift   = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)
    }

    var keyCode: UInt32          // virtual key code (kVK_*)
    var modifiers: Modifiers

    /// Carbon modifier mask for RegisterEventHotKey.
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.option)  { m |= UInt32(optionKey) }
        if modifiers.contains(.shift)   { m |= UInt32(shiftKey) }
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    /// From an AppKit key event's flags.
    static func modifiers(from flags: NSEvent.ModifierFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.control) { m.insert(.control) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.shift)   { m.insert(.shift) }
        if flags.contains(.command) { m.insert(.command) }
        return m
    }

    /// "⌃⌥⌘M" — the display string for the recorder chip.
    var display: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option)  { s += "⌥" }
        if modifiers.contains(.shift)   { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Storage form "keyCode:modifiers"; presence of the string = a
    /// recorded shortcut (keyCode 0 is a real key — kVK_ANSI_A).
    var storageValue: String { "\(keyCode):\(modifiers.rawValue)" }

    init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: ":")
        guard parts.count == 2, let k = UInt32(parts[0]), let m = UInt32(parts[1]) else { return nil }
        self.init(keyCode: k, modifiers: Modifiers(rawValue: m))
    }

    /// Human label for a virtual key code — letters/digits via the current
    /// layout, specials mapped by hand.
    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Return:        return "↩"
        case kVK_Tab:           return "⇥"
        case kVK_Space:         return "Space"
        case kVK_Delete:        return "⌫"
        case kVK_Escape:        return "⎋"
        case kVK_LeftArrow:     return "←"
        case kVK_RightArrow:    return "→"
        case kVK_UpArrow:       return "↑"
        case kVK_DownArrow:     return "↓"
        case kVK_F1...kVK_F1 + 19: return "F\(Int(keyCode) - kVK_F1 + 1)"
        default: break
        }
        // Translate through the current keyboard layout.
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let dataRef = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return "key \(keyCode)"
        }
        let data = unsafeBitCast(dataRef, to: CFData.self) as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let err = data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) -> OSStatus in
            let layout = ptr.bindMemory(to: UCKeyboardLayout.self).baseAddress!
            return UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                  &deadKeyState, chars.count, &length, &chars)
        }
        guard err == noErr, length > 0 else { return "key \(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// The system-wide shortcuts Burrow can register. Each action has a
/// Store slot and an optional handler; Settings ▸ Menu Bar records them.
enum HotKeyAction: UInt32, CaseIterable {
    case openBurrow = 1
    case keepScreenOn = 2
    case cleanScreen = 3

    var storeKey: String {
        switch self {
        case .openBurrow:   return "global_shortcut"
        case .keepScreenOn: return "awake_shortcut"
        case .cleanScreen:  return "clean_screen_shortcut"
        }
    }
}

/// Registers system-wide hot keys (one per HotKeyAction) and fires the
/// matching callback on press. Re-register by calling `apply` again.
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [HotKeyAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    var handlers: [HotKeyAction: () -> Void] = [:]

    private init() {}

    /// Register `hotKey` for `action` (or unregister it when nil).
    func apply(_ hotKey: HotKey?, for action: HotKeyAction = .openBurrow) {
        if let ref = refs[action] {
            UnregisterEventHotKey(ref)
            refs[action] = nil
        }
        guard let hk = hotKey else { return }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x42555257 /* 'BURW' */), id: action.rawValue)
        RegisterEventHotKey(hk.keyCode, hk.carbonModifiers, id,
                            GetApplicationEventTarget(), 0, &ref)
        refs[action] = ref
    }

    /// Register every recorded shortcut from the Store.
    func applyAll() {
        for action in HotKeyAction.allCases {
            apply(Store.shortcut(for: action), for: action)
        }
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            if let action = HotKeyAction(rawValue: hkID.id) {
                DispatchQueue.main.async { center.handlers[action]?() }
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        handlerInstalled = true
    }
}
