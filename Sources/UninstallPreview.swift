//
//  UninstallPreview.swift
//  Burrow
//
//  Parser + classifier for `mo uninstall --dry-run <app>` — the
//  enumeration behind the expandable leftover review (design 2.2).
//  Every path Burrow ever trashes selectively MUST come from this
//  enumeration: the engine's safety scan decided the candidate set,
//  Burrow only narrows it.
//
//  Output shape (mole 1.41, fixture in Tests/UninstallPreviewTests):
//
//      Files to be removed:
//
//      ◎ Maccy , 239.6MB
//        ✓ /Applications/Maccy.app
//        ✓ ~/Library/Containers/org.p0deje.Maccy
//        ...
//
//  Anything unrecognized parses to an empty preview and the UI falls
//  back to the classic whole-app flow.
//

import Foundation

struct UninstallPreview: Equatable {
    enum Kind: Equatable {
        case application, appSupport, preferences, container, groupContainer
        case helper, loginItem, cache, log, other

        /// Auto-selected kinds are the removal essentials. Caches, logs,
        /// group containers (shared between apps!) and unknowns need a
        /// human look first.
        var autoSelected: Bool {
            switch self {
            case .application, .appSupport, .preferences, .container, .helper, .loginItem:
                return true
            case .cache, .log, .groupContainer, .other:
                return false
            }
        }

        var label: String {
            switch self {
            case .application:    return NSLocalizedString("Application", comment: "uninstall kind")
            case .appSupport:     return NSLocalizedString("App Support", comment: "uninstall kind")
            case .preferences:    return NSLocalizedString("Preferences", comment: "uninstall kind")
            case .container:      return NSLocalizedString("Container", comment: "uninstall kind")
            case .groupContainer: return NSLocalizedString("Group Container", comment: "uninstall kind")
            case .helper:         return NSLocalizedString("Helper", comment: "uninstall kind")
            case .loginItem:      return NSLocalizedString("Login Item", comment: "uninstall kind")
            case .cache:          return NSLocalizedString("Temporary Cache", comment: "uninstall kind")
            case .log:            return NSLocalizedString("Logs", comment: "uninstall kind")
            case .other:          return NSLocalizedString("Other", comment: "uninstall kind")
            }
        }
    }

    struct Entry: Identifiable, Equatable {
        let path: String        // as printed (may be ~-relative)
        let kind: Kind
        var id: String { path }

        var expandedPath: String { (path as NSString).expandingTildeInPath }
    }

    let appName: String?
    let totalText: String?      // "239.6MB"
    let entries: [Entry]

    var isEmpty: Bool { entries.isEmpty }

    // MARK: - Parsing

    static func parse(_ lines: [String]) -> UninstallPreview {
        var appName: String?
        var totalText: String?
        var entries: [Entry] = []
        var inFileList = false

        for raw in lines {
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Files to be removed") { inFileList = true; continue }
            guard inFileList else { continue }
            if t.hasPrefix("➤") || t.hasPrefix("===") { break }

            if t.hasPrefix("◎") {
                // "◎ Maccy , 239.6MB"
                let body = t.dropFirst().trimmingCharacters(in: .whitespaces)
                if let comma = body.range(of: ",", options: .backwards) {
                    appName = String(body[..<comma.lowerBound]).trimmingCharacters(in: .whitespaces)
                    totalText = String(body[comma.upperBound...]).trimmingCharacters(in: .whitespaces)
                } else {
                    appName = body
                }
            } else if t.hasPrefix("✓") || t.hasPrefix("✔") {
                let path = String(t.dropFirst()).trimmingCharacters(in: .whitespaces)
                guard path.hasPrefix("/") || path.hasPrefix("~") else { continue }
                entries.append(Entry(path: path, kind: classify(path)))
            }
        }
        return UninstallPreview(appName: appName, totalText: totalText, entries: entries)
    }

    /// Path shape → kind. Order matters: more specific prefixes first.
    static func classify(_ path: String) -> Kind {
        let p = path.hasPrefix("~") ? path : (path as NSString).abbreviatingWithTildeInPath
        if p.hasSuffix(".app") { return .application }
        if p.contains("/Library/Group Containers/") { return .groupContainer }
        if p.contains("/Library/Containers/") { return .container }
        if p.contains("/Library/Application Support/") { return .appSupport }
        if p.contains("/Library/Preferences/") { return .preferences }
        if p.contains("/Library/Application Scripts/") { return .helper }
        if p.contains("/Library/LaunchAgents/") || p.contains("/Library/LaunchDaemons/") { return .loginItem }
        if p.contains("/Library/Caches/") || p.hasPrefix("/private/var/folders/")
            || p.hasPrefix("/var/folders/") || p.hasPrefix("/tmp/") || p.hasPrefix("/private/tmp/") { return .cache }
        if p.contains("/Library/Logs/") { return .log }
        return .other
    }
}
