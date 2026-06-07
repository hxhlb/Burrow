//
//  Explain.swift
//  Burrow
//
//  The "Explain" lens — a narrow, optional AI layer over Burrow's OWN
//  data. It is not a chatbot: it takes the latest sampled snapshot,
//  asks a model to explain it in plain English, and may suggest ONE
//  safe next step (Clean / Purge / Installers) that deep-links into the
//  existing confirm-gated flow. It never acts on its own.
//
//  Design split for testability:
//    * ExplainContext.build  — pure: snapshot → compact facts.
//    * ExplainPrompt.make    — pure: facts → (system, user) strings.
//    * ExplainResult.parse   — pure: model text → explanation + action.
//    * ExplainProvider       — the only impure seam (the network call);
//                              OllamaProvider is the local-default impl,
//                              and tests inject a fake.
//
//  Backends: local-first (Ollama on localhost) ships here; a
//  bring-your-own-key cloud provider is the next slice. Off by default;
//  when local, nothing leaves the machine.
//

import Foundation

// MARK: - Context

/// The compact, privacy-conscious set of facts we hand the model. Built
/// from the latest snapshot only — no raw history, no file contents.
struct ExplainContext: Equatable {
    let healthScore: Int
    let healthMsg: String
    let cpuUsage: Double
    let memUsedPercent: Double
    let memPressure: String
    let diskUsedPercent: Double?
    let topProcesses: [(name: String, cpu: Double, mem: Double)]
    let ageSeconds: Int

    static func == (l: ExplainContext, r: ExplainContext) -> Bool {
        l.healthScore == r.healthScore && l.cpuUsage == r.cpuUsage
            && l.memUsedPercent == r.memUsedPercent && l.memPressure == r.memPressure
            && l.diskUsedPercent == r.diskUsedPercent
            && l.topProcesses.map(\.name) == r.topProcesses.map(\.name)
    }

    /// Build from the most recent snapshot in the DB, or nil if none yet.
    static func build(db: DB) -> ExplainContext? {
        guard let row = db.findLatest(prefix: Sampler.snapshotPrefix),
              let data = row.json.data(using: .utf8),
              let s = try? JSONDecoder().decode(MoleStatus.self, from: data) else { return nil }
        let now = Int(Date().timeIntervalSince1970)
        let top = (s.topProcesses ?? []).sorted { $0.cpu > $1.cpu }.prefix(5)
            .map { (name: $0.name, cpu: $0.cpu, mem: $0.memory) }
        return ExplainContext(
            healthScore: s.healthScore,
            healthMsg: s.healthScoreMsg,
            cpuUsage: s.cpu.usage,
            memUsedPercent: s.memory.usedPercent,
            memPressure: s.memory.pressure,
            diskUsedPercent: s.disks.first?.usedPercent,
            topProcesses: Array(top),
            ageSeconds: max(0, now - row.ts))
    }

    /// Human-readable fact block for the prompt body.
    var factSheet: String {
        var lines = [
            "health_score: \(healthScore)/100 (\(healthMsg))",
            String(format: "cpu_usage: %.1f%%", cpuUsage),
            String(format: "memory_used: %.0f%% (pressure: %@)", memUsedPercent, memPressure as NSString),
        ]
        if let d = diskUsedPercent { lines.append(String(format: "disk_used: %.0f%%", d)) }
        if !topProcesses.isEmpty {
            let procs = topProcesses.map { String(format: "%@ (%.0f%% cpu, %.0f%% mem)", $0.name as NSString, $0.cpu, $0.mem) }
            lines.append("top_processes: " + procs.joined(separator: ", "))
        }
        lines.append("snapshot_age_seconds: \(ageSeconds)")
        return lines.joined(separator: "\n")
    }
}

// MARK: - Suggested action

/// The one safe next step an explanation may recommend. Each maps to a
/// pane Burrow already has, and only ever deep-links behind the existing
/// confirm sheet — the lens never runs anything itself.
enum ExplainSuggestion: String, Equatable {
    case clean, purge, installer

    var pane: Pane {
        switch self {
        case .clean:     return .tool(.clean)
        case .purge:     return .tool(.purge)
        case .installer: return .tool(.installer)
        }
    }

    var ctaLabel: String {
        switch self {
        case .clean:     return "Open Clean"
        case .purge:     return "Open Purge"
        case .installer: return "Open Installers"
        }
    }
}

// MARK: - Result

struct ExplainResult: Equatable {
    let explanation: String
    let suggestion: ExplainSuggestion?

    /// Parse the model's reply. We ask it to optionally end with a line
    /// `ACTION: clean|purge|installer|none`; everything before that is the
    /// explanation. Tolerant of a missing/unknown action (→ no suggestion).
    static func parse(_ raw: String) -> ExplainResult {
        var explanationLines: [String] = []
        var suggestion: ExplainSuggestion?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.uppercased().hasPrefix("ACTION:") {
                let value = t.dropFirst("ACTION:".count).trimmingCharacters(in: .whitespaces).lowercased()
                suggestion = ExplainSuggestion(rawValue: value)
                continue   // don't echo the directive into the explanation
            }
            explanationLines.append(String(line))
        }
        let explanation = explanationLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ExplainResult(explanation: explanation, suggestion: suggestion)
    }
}

// MARK: - Prompt

enum ExplainPrompt {
    static func make(_ ctx: ExplainContext) -> (system: String, user: String) {
        let system = """
        You explain a macOS user's current system health in plain, calm English. \
        You are given a single snapshot of metrics. Be concise (2–4 sentences). \
        Name the most likely cause of anything unusual and say whether it's normal \
        or worth acting on. Only recommend an action when the data clearly warrants \
        it. End your reply with exactly one line of the form `ACTION: clean`, \
        `ACTION: purge`, `ACTION: installer`, or `ACTION: none` — \
        clean = system/app caches, purge = old project build artifacts, \
        installer = leftover .dmg/.pkg files. Use `none` if nothing is needed.
        """
        let user = "Current snapshot:\n\(ctx.factSheet)"
        return (system, user)
    }
}

// MARK: - Provider seam

protocol ExplainProvider {
    func complete(system: String, user: String) async throws -> String
}

enum ExplainError: LocalizedError {
    case noData
    case providerUnavailable(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .noData: return "No snapshot yet — wait for the first sample."
        case .providerUnavailable(let m): return m
        case .badResponse: return "The model returned an unexpected response."
        }
    }
}

/// Local-default provider: talks to an Ollama server on localhost. No key,
/// nothing leaves the machine. If Ollama isn't running, surfaces an
/// actionable error rather than hanging.
struct OllamaProvider: ExplainProvider {
    var model: String = Store.aiOllamaModel
    var baseURL: URL = URL(string: "http://127.0.0.1:11434")!
    var session: URLSession = .shared

    /// Build the `/api/chat` request. Pure + non-private so it's testable.
    static func makeRequest(baseURL: URL, model: String, system: String, user: String) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func complete(system: String, user: String) async throws -> String {
        let req = try OllamaProvider.makeRequest(baseURL: baseURL, model: model, system: system, user: user)
        let data: Data
        do {
            (data, _) = try await session.data(for: req)
        } catch {
            throw ExplainError.providerUnavailable(
                "Couldn't reach a local model (Ollama on \(baseURL.host ?? "localhost")). Is it running? `ollama run \(model)`")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ExplainError.badResponse
        }
        return content
    }
}

// MARK: - Engine

/// Orchestrates build → ask → parse. The provider is injectable so tests
/// drive the whole flow with a fake instead of the network.
struct ExplainEngine {
    let provider: ExplainProvider

    init(provider: ExplainProvider = OllamaProvider()) {
        self.provider = provider
    }

    func explain(db: DB) async throws -> ExplainResult {
        guard let ctx = ExplainContext.build(db: db) else { throw ExplainError.noData }
        let (system, user) = ExplainPrompt.make(ctx)
        let raw = try await provider.complete(system: system, user: user)
        return ExplainResult.parse(raw)
    }
}
