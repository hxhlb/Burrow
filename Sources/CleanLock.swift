//
//  CleanLock.swift
//  Burrow
//
//  Maps clean-preview cache paths to running apps so the review screen
//  can badge them "App open", keep them unticked, and tell the user the
//  upside of quitting ("Close Helium … to clean another N GB"). The
//  classifier is pure; the AppKit edge (the live app list) is one call.
//

import Foundation
import AppKit

enum CleanLock {
    struct RunningApp {
        let bundleID: String
        let name: String
    }

    /// The live list, regular apps only — menu-bar agents and daemons
    /// aren't something the user can reasonably "close".
    static func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(bundleID: app.bundleIdentifier ?? "", name: name)
            }
    }

    /// Whether `path` belongs to one of `running`'s caches: a path
    /// component equal to the app's bundle id (Containers/, Caches/) or
    /// exactly the app's name (Application Support/<Name>/…).
    static func lockReason(for path: String,
                           running: [RunningApp]) -> CleanSelection.LockReason? {
        let components = Set((path as NSString).pathComponents)
        for app in running {
            if !app.bundleID.isEmpty, components.contains(app.bundleID) {
                return .appOpen(appName: app.name)
            }
            if components.contains(app.name) {
                return .appOpen(appName: app.name)
            }
        }
        return nil
    }

    /// The full map for a parsed preview.
    static func lockedPaths(in list: CleanList,
                            running: [RunningApp]) -> [String: CleanSelection.LockReason] {
        var out: [String: CleanSelection.LockReason] = [:]
        for item in list.categories.flatMap(\.items) {
            if let reason = lockReason(for: item.path, running: running) {
                out[item.path] = reason
            }
        }
        return out
    }
}
