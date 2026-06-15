//
//  InventoryDiff.swift
//  Burrow
//
//  Set-membership diffing for periodic inventories (roadmap B.8 + D.12).
//  Pure: two lists of identifiers in, what was added/removed out. Apps,
//  login items, LaunchAgents, listening ports, and top-process membership
//  all diff the same way, so `burrow_diff` ("what changed since <time>") and
//  the new-LaunchAgent watcher ("a persistence item appeared") share one
//  audited implementation instead of each hand-rolling set math.
//

import Foundation

enum InventoryDiff {
    struct Change: Equatable {
        let added: [String]
        let removed: [String]
        /// Nothing moved — lets callers skip "what changed" sections and
        /// suppress no-op alerts.
        var isEmpty: Bool { added.isEmpty && removed.isEmpty }
    }

    /// Added = present now but not before; removed = the reverse. Both are
    /// de-duplicated and sorted, so the output is stable regardless of how
    /// the inventories were ordered (DB row order, enumeration order).
    static func diff(old: [String], new: [String]) -> Change {
        let o = Set(old), n = Set(new)
        return Change(added: n.subtracting(o).sorted(),
                      removed: o.subtracting(n).sorted())
    }
}
