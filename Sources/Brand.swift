//
//  Brand.swift
//  Burrow
//
//  Burrow's visual language — a cool graphite ground, crisp ink, and a
//  single electric-blue accent for primary emphasis. Each tool still keeps
//  its own vivid accent (teal / violet / coral / azure / gold) for active
//  states, so the app reads as one calm surface with bright, purposeful
//  pops — not a window that re-tints itself per tool.
//
//  Every surface/text token is appearance-adaptive (dark + light), so the
//  whole shell follows the system theme. Type is the bundled brand set:
//    * mono / rounded / sans  — Geist + Geist Mono (registered in Fonts.swift)
//    * display / serif        — Cal Sans, the one expressive voice
//

import AppKit
import SwiftUI

extension Color {
    /// 0xRRGGBB literal → sRGB Color.
    init(hex: UInt, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// Appearance-adaptive sRGB colour: `dark` hex in dark mode, `light` hex
    /// in light mode, each with its own opacity. Backed by a dynamic NSColor
    /// so it re-resolves when the system (or window) appearance flips.
    static func adaptive(_ dark: UInt, _ light: UInt,
                         darkA: Double = 1, lightA: Double = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let isDark = ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            let a = isDark ? darkA : lightA
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: a)
        })
    }
}

enum Brand {
    // MARK: Ground — cool graphite (dark) / cool paper (light)
    static let base      = Color.adaptive(0x0E0F13, 0xF4F5F7)
    static let baseSoft  = Color.adaptive(0x15171C, 0xFFFFFF)
    static let nearBlack = Color.adaptive(0x0A0B0D, 0xE6E8EC)

    // MARK: Text — crisp off-white (dark) / near-black (light)
    static let ink           = Color.adaptive(0xE9EAEE, 0x14161B)
    static let textPrimary   = Color.adaptive(0xE9EAEE, 0x14161B)
    static let textSecondary = Color.adaptive(0xE9EAEE, 0x14161B, darkA: 0.62, lightA: 0.60)
    static let textTertiary  = Color.adaptive(0xE9EAEE, 0x14161B, darkA: 0.40, lightA: 0.42)

    // MARK: Surfaces — white lift (dark) / white lift over paper (light)
    static let hairline      = Color.adaptive(0xFFFFFF, 0x000000, darkA: 0.09, lightA: 0.12)
    static let cardFill      = Color.adaptive(0xFFFFFF, 0xFFFFFF, darkA: 0.045, lightA: 0.55)
    static let cardFillHover = Color.adaptive(0xFFFFFF, 0xFFFFFF, darkA: 0.08, lightA: 0.80)
    static let chipFill      = Color.adaptive(0xFFFFFF, 0x000000, darkA: 0.08, lightA: 0.06)
    static let trackFill     = Color.adaptive(0xFFFFFF, 0x000000, darkA: 0.10, lightA: 0.08)

    // MARK: Accent — one electric blue for primary emphasis (both modes)
    static let accent   = Color(hex: 0x5B8DEF)
    static let onAccent = Color(hex: 0x08101C)   // near-black text on any bright accent
    static let lilac    = Color(hex: 0xB7B2FF)
    static let apricot  = Color(hex: 0xFFD3B6)
    static let mint     = Color(hex: 0x8FE9D0)

    // MARK: Metric / per-tool accents (vivid pops, fixed across modes)
    static let green  = Color(hex: 0x3CB371)
    static let gold   = Color(hex: 0xE6A93C)
    static let amber  = Color(hex: 0xF0B24A)
    static let orange = Color(hex: 0xF0714E)
    static let blue   = Color(hex: 0x4FA3E3)
    static let red    = Color(hex: 0xF0604E)
    static let teal   = Color(hex: 0x16A37F)
    static let violet = Color(hex: 0x8E84F0)
    static let moss   = Color(hex: 0x6FB06A)
    static let ginger = Color(hex: 0xD98C5F)

    // MARK: Brand mark colours (the Burrow disc keeps a warm pop, both modes)
    static let cream    = Color(hex: 0xF3ECDD)
    static let espresso = Color(hex: 0x1A140E)

    // MARK: Shape — rounded, the house signature
    static let rSmall: CGFloat = 12
    static let rCard:  CGFloat = 18
    static let rLarge: CGFloat = 26

    /// A stable veil drawn over the window vibrancy — identical on every pane
    /// (no per-tool re-tint), adaptive to the system theme.
    static var windowVeil: LinearGradient {
        LinearGradient(
            colors: [Color.adaptive(0x15171C, 0xFBFBFD, darkA: 0.55, lightA: 0.45),
                     Color.adaptive(0x0B0C10, 0xEFF1F4, darkA: 0.82, lightA: 0.62)],
            startPoint: .top, endPoint: .bottom)
    }

    // MARK: Type — the bundled brand set (registered in Fonts.swift)
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.mono, size: size).weight(weight)
    }
    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.ui, size: size).weight(weight)
    }
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.ui, size: size).weight(weight)
    }
    /// The display / hero voice — Cal Sans.
    static func display(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.display, size: size).weight(weight)
    }
    static func serif(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom(Fonts.display, size: size).weight(weight)
    }
}
