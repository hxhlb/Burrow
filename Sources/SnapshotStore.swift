//
//  SnapshotStore.swift
//  Burrow
//
//  Typed read access to the metrics history the Sampler persists. The Sampler
//  stores each `mo status --json` snapshot (natively patched) as raw text keyed
//  by timestamp; every chart/tile consumer used to re-implement "load rows in a
//  range → decode each to MoleStatus → project". That decode-from-storage now
//  lives here, so consumers ask for typed snapshots and never touch raw JSON or
//  the database directly.
//

import Foundation

/// A persisted snapshot: Mole's timestamp plus the decoded status.
struct StoredSnapshot {
    let ts: Int
    let status: MoleStatus
}

enum SnapshotStore {
    private static let dec = JSONDecoder()

    /// Decoded snapshots in `[since, until]` (unix seconds), stride-sampled to at
    /// most `maxPoints`. Rows that fail to decode (schema drift, truncation) are
    /// skipped rather than failing the whole range.
    static func range(_ db: DB, since: Int, until: Int, maxPoints: Int) -> [StoredSnapshot] {
        db.findRangeSampled(prefix: Sampler.snapshotPrefix, since: since, until: until, maxPoints: maxPoints)
            .compactMap { row in
                (try? dec.decode(MoleStatus.self, from: Data(row.json.utf8)))
                    .map { StoredSnapshot(ts: row.ts, status: $0) }
            }
    }

    /// The most recent persisted snapshot, decoded.
    static func latest(_ db: DB) -> StoredSnapshot? {
        guard let row = db.findLatest(prefix: Sampler.snapshotPrefix),
              let s = try? dec.decode(MoleStatus.self, from: Data(row.json.utf8)) else { return nil }
        return StoredSnapshot(ts: row.ts, status: s)
    }
}
