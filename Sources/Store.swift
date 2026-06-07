//
//  Store.swift
//  Burrow
//
//  Typed access to UserDefaults for Burrow's settings. Each property
//  has a single key, an explicit default, and a clamp on read so a
//  malformed/old value can't blow up the consumer.
//
//  Defaults are conservative: 60 s sample interval, 30 day retention,
//  port 9277 (one above Stats's MCP so they coexist). Changes are
//  picked up at the next maintenance / sampler tick — there's no
//  notification fan-out yet because the only writer is the Settings
//  UI, and the affected components poll the Store on their own
//  schedule.
//

import Foundation

enum Store {
    private static let d = UserDefaults.standard

    // MARK: - Sampler

    /// Seconds between `mo status --json` invocations. Clamp to [5, 3600]
    /// because below 5 the subprocess overhead dominates, and above an
    /// hour the History view stops being useful at typical ranges.
    static var sampleIntervalSeconds: Int {
        get {
            let raw = d.integer(forKey: "sample_interval_seconds")
            return raw == 0 ? 60 : max(5, min(raw, 3600))
        }
        set {
            d.set(max(5, min(newValue, 3600)), forKey: "sample_interval_seconds")
        }
    }

    // MARK: - Retention

    /// History TTL in days. Older `samples` rows are pruned on the
    /// hourly maintenance tick. 0 / negative would delete everything
    /// immediately, so we clamp to ≥1.
    static var retentionDays: Int {
        get {
            let raw = d.integer(forKey: "retention_days")
            return raw == 0 ? 30 : max(1, raw)
        }
        set {
            d.set(max(1, newValue), forKey: "retention_days")
        }
    }

    /// Whether the maintenance scheduler should run VACUUM after a
    /// prune that deleted a non-trivial number of rows. Off by default
    /// — VACUUM rewrites the whole file and at typical churn (~1
    /// snapshot/minute) the freelist reclaim isn't worth the I/O.
    static var autoVacuum: Bool {
        get { d.object(forKey: "auto_vacuum") as? Bool ?? false }
        set { d.set(newValue, forKey: "auto_vacuum") }
    }

    // MARK: - AI (Explain lens)

    /// Whether the optional "Explain" AI lens is enabled. Off by default —
    /// it's opt-in, and when on it defaults to a local model so nothing
    /// leaves the Mac.
    static var aiEnabled: Bool {
        get { d.object(forKey: "ai_enabled") as? Bool ?? false }
        set { d.set(newValue, forKey: "ai_enabled") }
    }

    /// The local Ollama model the Explain lens talks to. Small + fast by
    /// default; the user can point it at any model they've pulled.
    static var aiOllamaModel: String {
        get {
            let v = (d.string(forKey: "ai_ollama_model") ?? "").trimmingCharacters(in: .whitespaces)
            return v.isEmpty ? "llama3.2" : v
        }
        set { d.set(newValue, forKey: "ai_ollama_model") }
    }

    // MARK: - MCP / QueryServer

    /// Localhost port for the JSON HTTP server. 9277 by default
    /// (Stats's MCP uses 9276, so they don't collide if both are
    /// installed). Restart required to change.
    static var queryServerPort: Int {
        get {
            let raw = d.integer(forKey: "query_server_port")
            return raw == 0 ? Int(QueryServer.defaultPort) : raw
        }
        set { d.set(newValue, forKey: "query_server_port") }
    }

    /// Whether the QueryServer should bind at launch. Off-switch for
    /// users who only want the popup + cleanup features and don't want
    /// a localhost listener.
    static var queryServerEnabled: Bool {
        get { d.object(forKey: "query_server_enabled") as? Bool ?? true }
        set { d.set(newValue, forKey: "query_server_enabled") }
    }

    // MARK: - Privacy

    /// Whether the user has dismissed the Full Disk Access notice that
    /// Burrow shows before scans which walk TCC-protected directories
    /// (issue #3). Defaults to false so first-run users see it once;
    /// sticks once dismissed so we never nag.
    static var fullDiskAccessNoticeDismissed: Bool {
        get { d.object(forKey: "fda_notice_dismissed") as? Bool ?? false }
        set { d.set(newValue, forKey: "fda_notice_dismissed") }
    }

    // MARK: - History view

    /// Last-selected History view range, in minutes. Persisting it
    /// across launches matches the muscle-memory of the Stats fork:
    /// users converge on one range and want it sticky.
    static var lastHistoryRangeMinutes: Int {
        get {
            let raw = d.integer(forKey: "last_history_range_minutes")
            return raw == 0 ? 60 : raw  // default 1h
        }
        set { d.set(newValue, forKey: "last_history_range_minutes") }
    }
}
