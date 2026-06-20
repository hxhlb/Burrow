//
//  UpdateCheck.swift
//  Burrow
//
//  "Check for Updates": one GET to the GitHub Releases API, compare against
//  the running version, then point the user at the release page (or
//  `brew upgrade --cask burrow` when the cask receipt is present). Two
//  callers share the fetch/parse/compare: the manual menu/Settings action
//  (UpdateCheck.checkNow, an NSAlert) and the opt-in background check
//  (AppUpdate, default on — a silent launch + ~daily GET that surfaces a
//  banner + menu-bar dot). Neither installs anything; self-update waits for
//  signed/notarized distribution. The background check is documented in
//  SECURITY.md.
//

import Foundation
import AppKit

extension Notification.Name {
    /// Posted (object: Bool — whether an update is available) when the
    /// background self-update state changes, so the menu-bar status item can
    /// add/remove its dot without holding a Combine subscription.
    static let burrowUpdateAvailability = Notification.Name("dev.caezium.burrow.updateAvailability")
}

/// The background half of self-update: a silent, opt-in, ~daily GitHub check
/// that publishes a found release for the in-window banner + menu-bar dot.
/// The loud manual half (NSAlert) stays in `UpdateCheck.checkNow()`.
@MainActor
final class AppUpdate: ObservableObject {
    static let shared = AppUpdate()

    /// The newest release when it's newer than this build and not dismissed;
    /// nil otherwise. Drives the RootView banner + PopupView footer row.
    @Published private(set) var available: UpdateCheck.Release?

    private var timer: Timer?

    /// Start the launch check + a ~daily repeating check. Safe to call once
    /// from AppDelegate; honours the opt-in internally so toggling the
    /// setting off stops surfacing (a running timer just no-ops).
    func begin() {
        checkIfDue()
        // Re-check ~daily for long-running menu-bar sessions.
        let t = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkIfDue() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Fetch if the opt-in is on and we haven't checked in ~a day.
    func checkIfDue() {
        guard Store.autoCheckForUpdates else { return }
        if let last = Store.lastUpdateCheckAt, Date().timeIntervalSince(last) < 23 * 3600 { return }
        fetch()
    }

    /// Force a fetch now (the Settings "Check for Updates" path / turning
    /// auto-check on). Ignores the throttle but still publishes silently.
    func checkNow() { fetch() }

    /// Drop the current banner and suppress this version until a newer one.
    func dismiss() {
        if let v = available?.version { Store.dismissedUpdateVersion = v }
        setAvailable(nil)
    }

    private func fetch() {
        var request = URLRequest(url: UpdateCheck.latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            DispatchQueue.main.async {
                Store.lastUpdateCheckAt = Date()
                guard let data,
                      let release = UpdateCheck.parseLatestRelease(data),
                      UpdateCheck.isNewer(release.version, than: UpdateCheck.currentVersion),
                      release.version != Store.dismissedUpdateVersion else {
                    self.setAvailable(nil)
                    return
                }
                self.setAvailable(release)
            }
        }.resume()
    }

    private func setAvailable(_ release: UpdateCheck.Release?) {
        available = release
        NotificationCenter.default.post(name: .burrowUpdateAvailability, object: release != nil)
    }
}

enum UpdateCheck {
    static let latestReleaseURL = URL(string: "https://api.github.com/repos/caezium/Burrow/releases/latest")!
    static let releasesPageURL  = URL(string: "https://github.com/caezium/Burrow/releases")!

    struct Release {
        let version: String
        let url: URL
    }

    /// Numeric per-component compare; tolerates a leading "v" and ragged
    /// lengths (missing components count as 0).
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            var t = s.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
            return t.split(separator: ".").map { Int($0) ?? 0 }
        }
        let r = parts(remote), l = parts(local)
        for i in 0..<max(r.count, l.count) {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv != lv { return rv > lv }
        }
        return false
    }

    /// Pull tag + page URL out of a /releases/latest response.
    static func parseLatestRelease(_ data: Data) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let urlString = obj["html_url"] as? String,
              let url = URL(string: urlString) else { return nil }
        var version = tag.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        guard !version.isEmpty else { return nil }
        return Release(version: version, url: url)
    }

    /// The version this build is running.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Whether this copy came from Homebrew (cask receipt present) — then
    /// the honest update path is `brew upgrade --cask burrow`.
    static func installedViaHomebrew() -> Bool {
        let caskrooms = ["/opt/homebrew/Caskroom/burrow", "/usr/local/Caskroom/burrow"]
        return caskrooms.contains { FileManager.default.fileExists(atPath: $0) }
    }

    /// The menu action: fetch, compare, and report via NSAlert. Stays
    /// entirely off the network until the user asks.
    static func checkNow() {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { data, _, error in
            DispatchQueue.main.async {
                guard let data, error == nil, let release = parseLatestRelease(data) else {
                    presentResult(title: NSLocalizedString("Couldn't check for updates", comment: ""),
                                  body: NSLocalizedString("GitHub didn't answer. Try again later, or open the releases page.", comment: ""),
                                  link: releasesPageURL)
                    return
                }
                if isNewer(release.version, than: currentVersion) {
                    let brew = installedViaHomebrew()
                    let body = brew
                        ? String(format: NSLocalizedString("Burrow %@ is available (you have %@). Update and relaunch with Homebrew, or open the release page.", comment: ""), release.version, currentVersion)
                        : String(format: NSLocalizedString("Burrow %@ is available (you have %@). Download it from the release page.", comment: ""), release.version, currentVersion)
                    presentResult(title: NSLocalizedString("Update available", comment: ""), body: body, link: release.url, brewUpgrade: brew)
                } else {
                    presentResult(title: NSLocalizedString("You're up to date", comment: ""),
                                  body: String(format: NSLocalizedString("Burrow %@ is the latest release.", comment: ""), currentVersion),
                                  link: nil)
                }
            }
        }.resume()
    }

    private static func presentResult(title: String, body: String, link: URL?, brewUpgrade: Bool = false) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        // Button order defines the response order: Update (default) · Release page · Close.
        if brewUpgrade { alert.addButton(withTitle: NSLocalizedString("Update with Homebrew", comment: "")) }
        if link != nil { alert.addButton(withTitle: NSLocalizedString("Open Release Page", comment: "")) }
        alert.addButton(withTitle: NSLocalizedString("Close", comment: ""))
        NSApp.activate(ignoringOtherApps: true)
        let resp = alert.runModalQuiet()
        if brewUpgrade {
            if resp == .alertFirstButtonReturn { homebrewUpgrade() }
            else if resp == .alertSecondButtonReturn, let link { NSWorkspace.shared.open(link) }
        } else if resp == .alertFirstButtonReturn, let link {
            NSWorkspace.shared.open(link)
        }
    }

    /// User-initiated one-click update for Homebrew installs: run
    /// `brew upgrade --cask burrow` in Terminal, then relaunch. Still entirely
    /// user-driven — nothing installs without this click. Uses a `.command`
    /// file (no Automation/AppleScript permission needed): it waits for this
    /// app to quit so the bundle can be swapped cleanly, upgrades, then reopens
    /// Burrow. Terminal runs in the user's login shell, so `brew` is on PATH.
    static func homebrewUpgrade() {
        let script = """
        #!/bin/bash
        echo "Updating Burrow via Homebrew — it'll reopen when this finishes."
        echo
        for _ in $(seq 1 60); do pgrep -x Burrow >/dev/null 2>&1 || break; sleep 0.5; done
        brew upgrade --cask burrow
        code=$?
        echo
        if [ $code -eq 0 ]; then
          echo "Updated. Relaunching Burrow…"
          open -a Burrow
        else
          echo "Update failed (exit $code). Grab it from \(releasesPageURL.absoluteString)"
        fi
        """
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("burrow-update.command")
        do {
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        } catch {
            NSWorkspace.shared.open(releasesPageURL)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        // Quit so the .command can replace the bundle and relaunch the new build.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
}
