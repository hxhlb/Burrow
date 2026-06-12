//
//  UpdateCheck.swift
//  Burrow
//
//  Manual-only "Check for Updates": one GET to the GitHub Releases API,
//  compare against the running version, then point the user at the
//  release page (or `brew upgrade --cask burrow` when the cask receipt
//  is present). Never automatic, never silent — the request happens only
//  on the menu click, matching the documented network story. Self-update
//  waits for signed/notarized distribution.
//

import Foundation
import AppKit

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
                    let body = installedViaHomebrew()
                        ? String(format: NSLocalizedString("Burrow %@ is available (you have %@). Update with `brew upgrade --cask burrow`, or open the release page.", comment: ""), release.version, currentVersion)
                        : String(format: NSLocalizedString("Burrow %@ is available (you have %@). Download it from the release page.", comment: ""), release.version, currentVersion)
                    presentResult(title: NSLocalizedString("Update available", comment: ""), body: body, link: release.url)
                } else {
                    presentResult(title: NSLocalizedString("You're up to date", comment: ""),
                                  body: String(format: NSLocalizedString("Burrow %@ is the latest release.", comment: ""), currentVersion),
                                  link: nil)
                }
            }
        }.resume()
    }

    private static func presentResult(title: String, body: String, link: URL?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        if link != nil {
            alert.addButton(withTitle: NSLocalizedString("Open Release Page", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Close", comment: ""))
        } else {
            alert.addButton(withTitle: NSLocalizedString("Close", comment: ""))
        }
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn, let link {
            NSWorkspace.shared.open(link)
        }
    }
}
