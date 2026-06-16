//
//  RestorePlan.swift
//  Burrow
//
//  "Restore last cleanup" planning (roadmap D.13). Pure: the items a cleanup
//  session moved + a probe for what's currently at each origin → a per-item
//  verdict on what can actually be put back. Honest by construction: only
//  Trash-based removals are recoverable (Clean's cache deletions are
//  permanent by design), and an origin that's been re-created is a collision,
//  not a silent overwrite. Doing the Finder "put back" / move is integration.
//

import Foundation

enum RestorePlan {
    /// One recorded removal from `mo history --json`.
    struct Item: Equatable {
        let originalPath: String
        /// Mole's action: "trash" (recoverable) or "remove" (permanent).
        let action: String
    }

    struct Entry: Equatable {
        let path: String
        let restorable: Bool
        let reason: String
    }

    /// Build the plan. `existsAtOriginal` probes the live filesystem (injected
    /// so the decision logic stays pure and testable).
    static func build(_ items: [Item], existsAtOriginal: (String) -> Bool) -> [Entry] {
        items.map { item in
            guard item.action == "trash" else {
                return Entry(path: item.originalPath, restorable: false,
                             reason: "permanently removed — not recoverable")
            }
            if existsAtOriginal(item.originalPath) {
                return Entry(path: item.originalPath, restorable: false,
                             reason: "a file already exists at the original path")
            }
            return Entry(path: item.originalPath, restorable: true, reason: "recoverable from Trash")
        }
    }

    /// Convenience: how many of a plan can actually be restored.
    static func restorableCount(_ plan: [Entry]) -> Int { plan.filter(\.restorable).count }

    /// Parse Mole's tab-separated deletion log (`ts\taction\tcategory\tstatus\tpath`)
    /// into restore candidates: entries that succeeded (`status == "ok"`),
    /// newest first. The path is the remainder so an embedded tab survives.
    static func parseLog(_ text: String) -> [Item] {
        var out: [Item] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let p = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
            guard p.count >= 5, p[3] == "ok" else { continue }
            out.append(Item(originalPath: p[4], action: p[1]))
        }
        return out.reversed()
    }
}
