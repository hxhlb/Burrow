//
//  Fonts.swift
//  Burrow
//
//  Registers the bundled brand typefaces at launch so SwiftUI's
//  Font.custom(...) can reach them:
//
//    * Geist       — UI text + numerics (the body voice)
//    * Geist Mono  — labels / the nav / the "instrument" voice
//    * Cal Sans    — the display / hero voice (headings, taglines)
//
//  The TTFs ship in the app bundle. Xcode flattens resource subfolders on
//  copy, so we look in both the Resources root and a `Fonts` subdirectory
//  and register process-scoped — no Info.plist ATSApplicationFontsPath
//  dependency on where exactly the file lands.
//

import CoreText
import Foundation

enum Fonts {
    /// Family names as registered — used by Brand.swift's Font.custom calls.
    static let ui = "Geist"
    static let mono = "Geist Mono"
    static let display = "Cal Sans"

    /// Idempotent: CoreText ignores a second registration of the same URL.
    static func register() {
        for file in ["Geist", "GeistMono", "CalSans"] {
            let url = Bundle.main.url(forResource: file, withExtension: "ttf")
                ?? Bundle.main.url(forResource: file, withExtension: "ttf", subdirectory: "Fonts")
            guard let url else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
