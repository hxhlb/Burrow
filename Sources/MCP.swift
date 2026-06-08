//
//  MCP.swift
//  Burrow
//
//  Stdio MCP (Model Context Protocol) server. When Burrow is launched
//  with `--mcp`, the GUI path is skipped and this loop takes over,
//  reading JSON-RPC 2.0 messages from stdin and writing responses to
//  stdout (line-delimited).
//
//  This isn't a long-lived service — Claude Code spawns the binary on
//  demand and keeps it alive only while the conversation is live. Each
//  spawn opens its own SQLite handle into the same `burrow.db` the GUI
//  app writes to. SQLite WAL means the spawn can read concurrently
//  with the GUI's sampler write loop.
//
//  Protocol surface implemented:
//    * initialize → server info + capabilities
//    * notifications/initialized → no-op (notification, no response)
//    * tools/list → fixed set, see ToolCatalog
//    * tools/call → dispatched to the catalog
//
//  All other methods return JSON-RPC error -32601 (method not found).
//  Tool results are wrapped as `{content: [{type: "text", text: "..."}]}`
//  per MCP convention — the text payload is the actual JSON we want
//  the agent to read.
//
//  Wire it up in your Claude Code config (`~/.claude/settings.json`):
//
//      {
//        "mcpServers": {
//          "burrow": {
//            "command": "/Applications/Burrow.app/Contents/MacOS/Burrow",
//            "args": ["--mcp"]
//          }
//        }
//      }
//

import Foundation

enum MCP {
    static func runStdioLoop() {
        // Open the DB read-only-ish — the MCP shim never inserts, but
        // SQLite needs RW to open in WAL mode. The GUI's sampler
        // handles all writes; we just read.
        let db: DB
        do {
            db = try DB.openDefault()
        } catch {
            stderr("burrow --mcp: failed to open DB: \(error.localizedDescription)")
            exit(1)
        }
        let server = MCPServer(db: db)
        server.serve(input: FileHandle.standardInput,
                     output: FileHandle.standardOutput)
    }

    /// Diagnostic logging. Goes to stderr so it doesn't pollute the
    /// JSON-RPC stream on stdout. Claude Code typically captures stderr
    /// into its agent log file.
    fileprivate static func stderr(_ s: String) {
        FileHandle.standardError.write(Data((s + "\n").utf8))
    }
}

// MARK: - Server

final class MCPServer {
    private let db: DB
    private let dec = JSONDecoder()
    private let enc = JSONEncoder()
    private let catalog: ToolCatalog

    init(db: DB) {
        self.db = db
        self.catalog = ToolCatalog(db: db)
        self.enc.outputFormatting = [.withoutEscapingSlashes]
    }

    /// Drive the loop. Reads line by line from `input`; one JSON-RPC
    /// message per line is the de-facto standard for stdio MCP. Exits
    /// cleanly on EOF.
    func serve(input: FileHandle, output: FileHandle) {
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }   // EOF — peer closed
            buffer.append(chunk)
            while let nl = buffer.firstIndex(of: 0x0A) {
                let line = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                if line.isEmpty { continue }
                self.handleLine(line, output: output)
            }
        }
    }

    private func handleLine(_ data: Data, output: FileHandle) {
        // Decode the JSON-RPC envelope loosely — we only care about
        // jsonrpc/id/method/params. Use a flexible decode so we can
        // tell notifications (no id) from requests (with id).
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.write(output, MCPServer.errorResponse(id: nil, code: -32700,
                                                      message: "parse error"))
            return
        }
        let method = (raw["method"] as? String) ?? ""
        let id = raw["id"]   // may be nil for notifications

        switch method {
        case "initialize":
            self.write(output, self.initializeResponse(id: id))
        case "notifications/initialized":
            // Notification — no response. The client is just telling us
            // it processed our initialize response.
            return
        case "tools/list":
            self.write(output, self.toolsListResponse(id: id))
        case "tools/call":
            self.handleToolsCall(raw: raw, id: id, output: output)
        default:
            // Notifications have no id; don't reply with an error to
            // them, that would be malformed JSON-RPC.
            if id != nil {
                self.write(output, MCPServer.errorResponse(id: id, code: -32601,
                                                          message: "method not found: \(method)"))
            }
        }
    }

    // MARK: - Method handlers

    private func initializeResponse(id: Any?) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": [
                "protocolVersion": "2024-11-05",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": [
                    "name": "burrow",
                    "version": "0.3.0",
                ],
            ],
        ]
    }

    private func toolsListResponse(id: Any?) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "result": ["tools": self.catalog.descriptors()],
        ]
    }

    private func handleToolsCall(raw: [String: Any], id: Any?, output: FileHandle) {
        let params = raw["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        do {
            let resultText = try self.catalog.call(name: name, arguments: args)
            self.write(output, [
                "jsonrpc": "2.0",
                "id": id as Any,
                "result": [
                    "content": [
                        ["type": "text", "text": resultText],
                    ],
                ],
            ])
        } catch let MCPToolError.unknown(toolName) {
            self.write(output, MCPServer.errorResponse(id: id, code: -32602,
                                                      message: "unknown tool: \(toolName)"))
        } catch let MCPToolError.badArguments(reason) {
            self.write(output, MCPServer.errorResponse(id: id, code: -32602,
                                                      message: "bad arguments: \(reason)"))
        } catch {
            self.write(output, MCPServer.errorResponse(id: id, code: -32603,
                                                      message: "internal error: \(error.localizedDescription)"))
        }
    }

    // MARK: - Plumbing

    private func write(_ fh: FileHandle, _ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object,
                                                     options: [.withoutEscapingSlashes]) else {
            return
        }
        data.append(0x0A)
        try? fh.write(contentsOf: data)
    }

    static func errorResponse(id: Any?, code: Int, message: String) -> [String: Any] {
        return [
            "jsonrpc": "2.0",
            "id": id as Any,
            "error": ["code": code, "message": message],
        ]
    }
}

// MARK: - Tool catalog

enum MCPToolError: Error {
    case unknown(String)
    case badArguments(String)
}

/// Burrow's MCP tools. Each one is a thin wrapper around a DB query
/// that returns a JSON string — agents read the text and parse it.
struct ToolCatalog {
    let db: DB

    /// Tool descriptors for `tools/list`. The inputSchema mirrors the
    /// JSON-Schema subset MCP expects; we keep them minimal.
    func descriptors() -> [[String: Any]] {
        return [
            [
                "name": "burrow_snapshot",
                "description": "Most recent Mole status snapshot (CPU, memory, disk, network, thermal, top processes, system health). Returns the full JSON Mole produced.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_history",
                "description": "Time-series slice of Mole snapshots. `minutes` selects how far back to look (default 60). `samples` caps the number of returned points via stride sampling (default 60, max 720).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "samples": ["type": "integer", "minimum": 1, "maximum": 720],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_top_processes",
                "description": "Top processes (by peak CPU%) across the last `minutes` window (default 60). Aggregates Mole's per-tick top_processes lists.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_process_usage",
                "description": "Rank processes over the last `minutes` (default 60) by a chosen `metric`: cpu_time (default; cumulative CPU-seconds = the closest answer to 'what used my computer most'), peak_cpu (highest single-sample CPU%), avg_cpu (mean CPU% while present), or peak_mem (highest memory%). Returns the window it actually used (start_ts/end_ts/sample_count) so the answer isn't ambiguous. NOTE: derived from periodic samples, so cpu_time is an estimate, not the kernel's exact accounting.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "minutes": ["type": "integer", "minimum": 1],
                        "metric": ["type": "string", "enum": ["cpu_time", "peak_cpu", "avg_cpu", "peak_mem"]],
                        "limit": ["type": "integer", "minimum": 1, "maximum": 100],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_info",
                "description": "Burrow's own state: list of prefixes with row counts + staleness, current retention setting. Use when diagnosing whether data is flowing.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_cleanup_history",
                "description": "Mole's itemised record of past cleanup activity: each clean/optimize/purge/uninstall session with when it ran, how many items, bytes freed, and an actions breakdown (removed/trashed/skipped/failed). `limit` caps how many recent sessions (default 20, max 200). This is Mole's CLEANUP log — distinct from burrow_history, which is the system-metrics time series. Read-only.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 200],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
            [
                "name": "burrow_deleted_files",
                "description": "The exact filesystem paths Mole has removed or trashed, newest first, from Mole's deletion log. Each entry has a timestamp, action (trash/remove), category, status (ok/failed), and the absolute path. `limit` caps how many recent paths (default 100, max 5000). Answers 'what exactly did the last cleanup delete?'. Read-only — this reports history, it does not delete anything.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "limit": ["type": "integer", "minimum": 1, "maximum": 5000],
                    ],
                    "additionalProperties": false,
                ] as [String: Any],
            ],
        ]
    }

    func call(name: String, arguments: [String: Any]) throws -> String {
        switch name {
        case "burrow_snapshot":
            return self.callSnapshot()
        case "burrow_history":
            return try self.callHistory(arguments)
        case "burrow_top_processes":
            return try self.callTopProcesses(arguments)
        case "burrow_process_usage":
            return try self.callProcessUsage(arguments)
        case "burrow_info":
            return self.callInfo()
        case "burrow_cleanup_history":
            return self.callCleanupHistory(arguments)
        case "burrow_deleted_files":
            return self.callDeletedFiles(arguments)
        default:
            throw MCPToolError.unknown(name)
        }
    }

    // MARK: Tool implementations

    private func callSnapshot() -> String {
        guard let row = self.db.findLatest(prefix: Sampler.snapshotPrefix) else {
            return "{\"error\":\"no snapshot yet\"}"
        }
        return "{\"ts\":\(row.ts),\"snapshot\":\(row.json)}"
    }

    private func callHistory(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        let samples = max(1, min((args["samples"] as? Int) ?? 60, 720))
        guard minutes > 0 else { throw MCPToolError.badArguments("minutes must be positive") }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        let rows = self.db.findRangeSampled(prefix: Sampler.snapshotPrefix,
                                            since: since, until: now,
                                            maxPoints: samples)
        var pieces: [String] = []
        pieces.reserveCapacity(rows.count)
        for r in rows {
            pieces.append("{\"ts\":\(r.ts),\"snapshot\":\(r.json)}")
        }
        return "{\"count\":\(rows.count),\"rows\":[\(pieces.joined(separator: ","))]}"
    }

    private func callTopProcesses(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        guard minutes > 0 else { throw MCPToolError.badArguments("minutes must be positive") }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        // 720 sampled rows over the window is the same budget the
        // HistoryView uses — enough to catch any process that peaked.
        let rows = self.db.findRangeSampled(prefix: Sampler.snapshotPrefix,
                                            since: since, until: now,
                                            maxPoints: 720)
        var peakCPU: [String: Double] = [:]
        var peakMem: [String: Double] = [:]
        let dec = JSONDecoder()
        for r in rows {
            guard let data = r.json.data(using: .utf8) else { continue }
            guard let s = try? dec.decode(MoleStatus.self, from: data) else { continue }
            for p in (s.topProcesses ?? []) {
                if p.cpu > (peakCPU[p.name] ?? 0)    { peakCPU[p.name] = p.cpu }
                if p.memory > (peakMem[p.name] ?? 0) { peakMem[p.name] = p.memory }
            }
        }
        let top = peakCPU.sorted { $0.value > $1.value }.prefix(limit)
        var pieces: [String] = []
        for (name, cpu) in top {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
            pieces.append("{\"name\":\"\(escaped)\",\"peak_cpu\":\(cpu),\"peak_mem\":\(peakMem[name] ?? 0)}")
        }
        return "{\"window_minutes\":\(minutes),\"processes\":[\(pieces.joined(separator: ","))]}"
    }

    /// Semantic process ranking. Where `burrow_top_processes` always ranks
    /// by peak CPU — which crowns a one-second spike — this lets the agent
    /// pick the metric that matches the question, and echoes the window it
    /// used so "this week" can't be silently reinterpreted.
    private func callProcessUsage(_ args: [String: Any]) throws -> String {
        let minutes = (args["minutes"] as? Int) ?? 60
        // Upper bound guards against Int overflow in `minutes * 60` below
        // (~1.9 years is far past any useful window).
        guard minutes > 0, minutes <= 1_000_000 else {
            throw MCPToolError.badArguments("minutes must be between 1 and 1000000")
        }
        let limit = max(1, min((args["limit"] as? Int) ?? 10, 100))
        let metric = (args["metric"] as? String) ?? "cpu_time"
        let allowed = ["cpu_time", "peak_cpu", "avg_cpu", "peak_mem"]
        guard allowed.contains(metric) else {
            throw MCPToolError.badArguments("metric must be one of: \(allowed.joined(separator: ", "))")
        }

        let now = Int(Date().timeIntervalSince1970)
        let since = now - minutes * 60
        let rows = self.db.findRangeSampled(prefix: Sampler.snapshotPrefix,
                                            since: since, until: now, maxPoints: 720)
        // findRangeSampled down-samples wide windows, so each returned row
        // stands for MORE than one sample period. Estimate CPU-time against
        // the effective spacing of the rows we actually got — using the raw
        // sampler cadence would badly under-count over long windows.
        let interval: Double = rows.count > 1
            ? Double(max(1, rows[rows.count - 1].ts - rows[0].ts)) / Double(rows.count - 1)
            : Double(Store.sampleIntervalSeconds)

        struct Agg { var peakCPU = 0.0; var sumCPU = 0.0; var samples = 0; var peakMem = 0.0 }
        var agg: [String: Agg] = [:]
        let dec = JSONDecoder()
        for r in rows {
            guard let data = r.json.data(using: .utf8),
                  let s = try? dec.decode(MoleStatus.self, from: data) else { continue }
            for p in (s.topProcesses ?? []) {
                var a = agg[p.name] ?? Agg()
                a.peakCPU = max(a.peakCPU, p.cpu)
                a.sumCPU += p.cpu
                a.samples += 1
                a.peakMem = max(a.peakMem, p.memory)
                agg[p.name] = a
            }
        }

        func score(_ a: Agg) -> Double {
            switch metric {
            case "peak_cpu": return a.peakCPU
            case "avg_cpu":  return a.samples > 0 ? a.sumCPU / Double(a.samples) : 0
            case "peak_mem": return a.peakMem
            default:         return (a.sumCPU / 100.0) * interval   // est. CPU-seconds
            }
        }

        let ranked = agg.sorted { score($0.value) > score($1.value) }.prefix(limit)
        var pieces: [String] = []
        for (name, a) in ranked {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\")
                              .replacingOccurrences(of: "\"", with: "\\\"")
            let avg = a.samples > 0 ? a.sumCPU / Double(a.samples) : 0
            let cpuTime = (a.sumCPU / 100.0) * interval
            pieces.append("{\"name\":\"\(escaped)\",\"peak_cpu\":\(a.peakCPU),\"avg_cpu\":\(avg),\"est_cpu_time_seconds\":\(cpuTime),\"peak_mem\":\(a.peakMem),\"samples\":\(a.samples)}")
        }
        let startTS = rows.first?.ts ?? since
        let endTS = rows.last?.ts ?? now
        return "{\"metric\":\"\(metric)\",\"window_minutes\":\(minutes),\"start_ts\":\(startTS),\"end_ts\":\(endTS),\"sample_count\":\(rows.count),\"interval_seconds\":\(Int(interval.rounded())),\"processes\":[\(pieces.joined(separator: ","))]}"
    }

    private func callInfo() -> String {
        let now = Int(Date().timeIntervalSince1970)
        let prefixes = self.db.listPrefixes()
        var pieces: [String] = []
        for p in prefixes {
            if let row = self.db.findLatest(prefix: p) {
                pieces.append("{\"prefix\":\"\(p)\",\"latest_ts\":\(row.ts),\"age_seconds\":\(max(0, now - row.ts))}")
            } else {
                pieces.append("{\"prefix\":\"\(p)\",\"latest_ts\":null,\"age_seconds\":null}")
            }
        }
        return "{\"now\":\(now),\"retention_days\":\(Store.retentionDays),\"sample_interval_seconds\":\(Store.sampleIntervalSeconds),\"readers\":[\(pieces.joined(separator: ","))]}"
    }

    /// Itemised cleanup history (issue #2). Passes through `mo history
    /// --json` — already the exact shape an agent wants (sessions[] with
    /// command/time/items/size/actions). We don't reshape it so the
    /// contract tracks Mole's, not ours. Degrades to a valid empty/error
    /// object when `mo` isn't installed so the tool never throws.
    private func callCleanupHistory(_ args: [String: Any]) -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 20, 200))
        guard let res = try? MoleCLI.run(args: ["history", "--json", "--limit", "\(limit)"],
                                         timeout: 15),
              res.exitCode == 0 else {
            return "{\"error\":\"mo history unavailable\",\"sessions\":[]}"
        }
        let out = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return out.isEmpty ? "{\"sessions\":[]}" : out
    }

    /// Exact deleted file paths (issue #2). Reads Mole's append-only
    /// deletion log and returns the most recent `limit` rows, newest
    /// first. Read-only: this surfaces what Mole already deleted; it
    /// never removes anything. Graceful when the log is absent.
    private func callDeletedFiles(_ args: [String: Any]) -> String {
        let limit = max(1, min((args["limit"] as? Int) ?? 100, 5000))
        let logPath = Self.deletionsLogPath()
        let text = (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? ""
        let files = Self.parseDeletionLog(text, limit: limit)
        let out: [String: Any] = ["count": files.count, "log": logPath, "files": files]
        if let data = try? JSONSerialization.data(withJSONObject: out,
                                                  options: [.withoutEscapingSlashes]),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{\"count\":0,\"files\":[]}"
    }

    /// Parse Mole's tab-separated deletion log into newest-first entries.
    /// Each line is `ts \t action \t category \t status \t path`; the path
    /// is the remainder so an (unlikely) tab inside it survives. Malformed
    /// lines are skipped. Pure → unit-tested.
    static func parseDeletionLog(_ text: String, limit: Int) -> [[String: Any]] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        var entries: [[String: Any]] = []
        for line in lines.suffix(max(1, limit)) {
            let parts = line.split(separator: "\t", maxSplits: 4,
                                   omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 5 else { continue }
            entries.append([
                "ts": parts[0], "action": parts[1], "category": parts[2],
                "status": parts[3], "path": parts[4],
            ])
        }
        return entries.reversed()
    }

    /// Resolve Mole's deletion-log path from `mo history --json` (the
    /// source of truth), falling back to the standard location when `mo`
    /// isn't reachable.
    private static func deletionsLogPath() -> String {
        let fallback = (NSHomeDirectory() as NSString)
            .appendingPathComponent("Library/Logs/mole/deletions.log")
        guard let res = try? MoleCLI.run(args: ["history", "--json"], timeout: 10),
              res.exitCode == 0,
              let data = res.stdout.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let logs = obj["logs"] as? [String: Any],
              let p = logs["deletions"] as? String, !p.isEmpty else {
            return fallback
        }
        return p
    }
}
