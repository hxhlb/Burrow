//
//  MetricsStore.swift
//  Burrow
//
//  The one read/aggregation layer over the persisted metrics history.
//  Absorbs SnapshotStore and becomes the single implementation behind the
//  MCP tools, the HTTP query server, and the chart view models — the query
//  and aggregation semantics live here exactly once; callers own only
//  argument parsing and their frozen wire formats.
//
//  All methods are synchronous, read-only, and bounded by maxPoints; the
//  store is a value over the existing DB handle, callable from any queue
//  the DB is safe on (status quo: views on main, MCP/HTTP on their queues).
//

import Foundation

/// A persisted snapshot: Mole's timestamp plus the decoded status.
struct StoredSnapshot {
    let ts: Int
    let status: MoleStatus
}

/// Why a stored row failed to decode — coding-path-precise, so a blank
/// chart always has a visible cause ("missing key 'usage' at path 'cpu'"),
/// instead of rows vanishing silently when mo's schema drifts.
struct DriftReport: Equatable, Error {
    enum Kind: Equatable {
        case missingKey(key: String, path: String)
        case typeMismatch(expected: String, path: String)
        case dataCorrupted(path: String, detail: String)
        case notJSON
    }
    let kind: Kind
    /// Leading fragment of the offending row, enough to eyeball the drift.
    let snippet: String
    /// Timestamp of the row that failed.
    let ts: Int

    var message: String {
        switch kind {
        case .missingKey(let key, let path):
            return "missing key '\(key)' at path '\(path)'"
        case .typeMismatch(let expected, let path):
            return "type mismatch (expected \(expected)) at path '\(path)'"
        case .dataCorrupted(let path, let detail):
            return "data corrupted at path '\(path)': \(detail)"
        case .notJSON:
            return "row is not valid JSON"
        }
    }
}

/// Decoded snapshots plus what was skipped getting them — drift is data,
/// not a silent compactMap.
struct SnapshotSlice {
    let snapshots: [StoredSnapshot]
    let droppedRows: Int
    let firstSkip: DriftReport?
}

struct MetricsStore {
    /// Bare-key prefix for persisted snapshots: one row per `mo status`
    /// invocation, value = the raw (natively patched) JSON payload. Owned by
    /// the read side — the producer's sink and every query agree through it.
    static let snapshotPrefix = "mole.snapshot"

    let db: DB
    private static let dec = JSONDecoder()

    /// A time window in unix seconds. Every ranged query takes one.
    struct Window {
        let since: Int
        let until: Int
        static func lastMinutes(_ m: Int, now: Date = Date()) -> Window {
            let until = Int(now.timeIntervalSince1970)
            return Window(since: until - m * 60, until: until)
        }
    }

    /// The most recent persisted snapshot, decoded.
    func latest() -> StoredSnapshot? {
        guard let row = db.findLatest(prefix: MetricsStore.snapshotPrefix),
              let s = try? Self.dec.decode(MoleStatus.self, from: Data(row.json.utf8)) else { return nil }
        return StoredSnapshot(ts: row.ts, status: s)
    }

    /// Decoded snapshots in the window, stride-sampled to at most `maxPoints`.
    /// Rows that fail to decode (schema drift, truncation) are skipped — but
    /// COUNTED, with the first failure's coding path carried along, so a
    /// thinning chart has a visible cause.
    func snapshots(_ w: Window, maxPoints: Int = 720) -> SnapshotSlice {
        var decoded: [StoredSnapshot] = []
        var dropped = 0
        var firstSkip: DriftReport?
        for row in db.findRangeSampled(prefix: MetricsStore.snapshotPrefix,
                                       since: w.since, until: w.until, maxPoints: maxPoints) {
            switch Self.decodeRow(row) {
            case .success(let s): decoded.append(s)
            case .failure(let drift):
                dropped += 1
                if firstSkip == nil { firstSkip = drift }
            }
        }
        return SnapshotSlice(snapshots: decoded, droppedRows: dropped, firstSkip: firstSkip)
    }

    /// Decode one stored row, classifying any failure into a DriftReport.
    private static func decodeRow(_ row: DB.Row) -> Result<StoredSnapshot, DriftReport> {
        do {
            let s = try Self.dec.decode(MoleStatus.self, from: Data(row.json.utf8))
            return .success(StoredSnapshot(ts: row.ts, status: s))
        } catch {
            return .failure(Self.classify(error, row: row))
        }
    }

    private static func classify(_ error: Error, row: DB.Row) -> DriftReport {
        let snippet = String(row.json.prefix(120))
        func path(_ codingPath: [CodingKey]) -> String {
            codingPath.map(\.stringValue).joined(separator: ".")
        }
        let kind: DriftReport.Kind
        switch error as? DecodingError {
        case .keyNotFound(let key, let ctx):
            kind = .missingKey(key: key.stringValue, path: path(ctx.codingPath))
        case .typeMismatch(let type, let ctx):
            kind = .typeMismatch(expected: "\(type)", path: path(ctx.codingPath))
        case .valueNotFound(let type, let ctx):
            kind = .typeMismatch(expected: "\(type)", path: path(ctx.codingPath))
        case .dataCorrupted(let ctx):
            // An empty coding path means the payload never parsed as JSON
            // at all; anything deeper is a real value-level corruption.
            kind = ctx.codingPath.isEmpty
                ? .notJSON
                : .dataCorrupted(path: path(ctx.codingPath), detail: ctx.debugDescription)
        default:
            kind = .dataCorrupted(path: "", detail: error.localizedDescription)
        }
        return DriftReport(kind: kind, snippet: snippet, ts: row.ts)
    }

    /// The most recent stored row, verbatim — the MCP/HTTP wire formats embed
    /// this text directly, so it must never round-trip through a decoder.
    func latestRaw() -> (ts: Int, json: String)? {
        db.findLatest(prefix: MetricsStore.snapshotPrefix).map { ($0.ts, $0.json) }
    }

    /// Raw rows for any reader prefix in the window — verbatim, ascending ts.
    /// `maxPoints == nil` returns every row; a value stride-samples.
    func rawRows(prefix: String, _ w: Window, maxPoints: Int?) -> [(ts: Int, json: String)] {
        let rows = maxPoints.map {
            db.findRangeSampled(prefix: prefix, since: w.since, until: w.until, maxPoints: $0)
        } ?? db.findRange(prefix: prefix, since: w.since, until: w.until)
        return rows.map { ($0.ts, $0.json) }
    }

    /// Chart projection: one metric over the window. The closure owns the
    /// metric's meaning (which field, how to combine interfaces); the store
    /// owns iteration, decode-once, and nil-skipping — a nil projection means
    /// "no sample at this instant", never a fake zero.
    func series(_ w: Window, maxPoints: Int = 720,
                _ read: (MoleStatus) -> Double?) -> [(ts: Int, value: Double)] {
        snapshots(w, maxPoints: maxPoints).snapshots.compactMap { s in
            read(s.status).map { (s.ts, $0) }
        }
    }

    // MARK: Process aggregation

    /// Ranking metric. Raw values double as the MCP wire strings — pinned by
    /// MetricsStoreTests so a rename can't silently change the tool contract.
    enum ProcessRank: String, CaseIterable {
        case cpuTime = "cpu_time", peakCPU = "peak_cpu", avgCPU = "avg_cpu", peakMem = "peak_mem"
    }

    struct ProcessStats {
        let name: String
        var peakCPU = 0.0
        var avgCPU = 0.0
        var estCPUSeconds = 0.0
        var peakMem = 0.0
        var peakMemBytes: UInt64 = 0
        var samples = 0
    }

    /// Per-process aggregates over a window, computed once; callers choose
    /// the ranking. Carries the window metadata the wire formats echo back.
    struct ProcessWindow {
        let startTS: Int
        let endTS: Int
        let sampleCount: Int
        /// Effective spacing of the snapshots actually returned. The store
        /// down-samples wide windows, so each snapshot stands for MORE than
        /// one sample period — CPU-time estimated against the raw sampler
        /// cadence would badly under-count over long windows.
        let intervalSeconds: Double
        let stats: [ProcessStats]

        func ranked(by rank: ProcessRank, limit: Int) -> [ProcessStats] {
            func score(_ s: ProcessStats) -> Double {
                switch rank {
                case .peakCPU: return s.peakCPU
                case .avgCPU:  return s.avgCPU
                case .peakMem: return s.peakMem
                case .cpuTime: return s.estCPUSeconds
                }
            }
            return Array(stats.sorted { score($0) > score($1) }.prefix(limit))
        }
    }

    func processWindow(_ w: Window, maxPoints: Int = 720) -> ProcessWindow {
        let snaps = snapshots(w, maxPoints: maxPoints).snapshots
        let interval: Double = snaps.count > 1
            ? Double(max(1, snaps[snaps.count - 1].ts - snaps[0].ts)) / Double(snaps.count - 1)
            : Double(Store.sampleIntervalSeconds)

        struct Agg { var peakCPU = 0.0; var sumCPU = 0.0; var samples = 0
                     var peakMem = 0.0; var peakMemBytes: UInt64 = 0 }
        var agg: [String: Agg] = [:]
        for stored in snaps {
            for p in (stored.status.topProcesses ?? []) {
                var a = agg[p.name] ?? Agg()
                a.peakCPU = max(a.peakCPU, p.cpu)
                a.sumCPU += p.cpu
                a.samples += 1
                a.peakMem = max(a.peakMem, p.memory)
                if let mb = p.memoryBytes { a.peakMemBytes = max(a.peakMemBytes, mb) }
                agg[p.name] = a
            }
        }
        let stats = agg.map { name, a in
            ProcessStats(name: name,
                         peakCPU: a.peakCPU,
                         avgCPU: a.samples > 0 ? a.sumCPU / Double(a.samples) : 0,
                         estCPUSeconds: (a.sumCPU / 100.0) * interval,
                         peakMem: a.peakMem,
                         peakMemBytes: a.peakMemBytes,
                         samples: a.samples)
        }
        return ProcessWindow(startTS: snaps.first?.ts ?? w.since,
                             endTS: snaps.last?.ts ?? w.until,
                             sampleCount: snaps.count,
                             intervalSeconds: interval,
                             stats: stats)
    }

    // MARK: Reader staleness

    struct ReaderStatus {
        let prefix: String
        let latestTS: Int?
        let ageSeconds: Int?
    }

    /// One entry per reader prefix with the age of its newest row — the
    /// staleness readout behind `burrow_info` and `GET /info`.
    func readers(now: Int = Int(Date().timeIntervalSince1970)) -> [ReaderStatus] {
        db.listPrefixes().map { p in
            guard let row = db.findLatest(prefix: p) else {
                return ReaderStatus(prefix: p, latestTS: nil, ageSeconds: nil)
            }
            return ReaderStatus(prefix: p, latestTS: row.ts, ageSeconds: max(0, now - row.ts))
        }
    }
}
