//
//  PortInspector.swift
//  Burrow
//
//  Listening / connection inspector (roadmap C.10, extended). Native
//  enumeration (proc_listpids + proc_pidfdinfo socket info) and the
//  confirm-gated SIGTERM/SIGKILL are integration; this is the model plus the
//  pure rules: kill-safety, stable sort, and port-conflict detection.
//

import Foundation

/// A socket's role, so the UI can split "what's accepting connections here"
/// (listen) from "what is this talking to" (established).
enum ConnState: String, Equatable {
    case listen, established, other
}

struct ListeningPort: Equatable, Identifiable {
    let pid: Int
    let process: String
    let port: Int            // local port
    let proto: String        // "tcp" | "udp"
    let address: String      // local address ("*" when bound to any)
    let uid: Int
    // Connection dimension (defaults keep listen-only callers unchanged).
    var state: ConnState = .listen
    var remoteAddress: String? = nil   // foreign host for an established socket
    var remotePort: Int? = nil

    /// Stable identity across refreshes (a process can hold many connections).
    var id: String {
        "\(pid)-\(proto)-\(port)-\(state.rawValue)-\(remoteAddress ?? "")-\(remotePort ?? 0)"
    }

    /// "host:port" for an established socket, else nil.
    var remoteDisplay: String? {
        guard let a = remoteAddress, let p = remotePort else { return nil }
        return a.contains(":") ? "[\(a)]:\(p)" : "\(a):\(p)"   // bracket IPv6
    }

    /// Local bind, e.g. "*:3000" or "127.0.0.1:5432".
    var localDisplay: String {
        address == "*" ? "*:\(port)" : (address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)")
    }
}

enum PortInspector {
    /// We only offer to kill a process the user actually owns. Root-owned
    /// (uid 0) and other users' processes are shown read-only — killing a
    /// system daemon by accident is exactly the footgun to avoid.
    static func isKillable(_ p: ListeningPort, currentUID: Int) -> Bool {
        p.uid != 0 && p.uid == currentUID
    }

    /// Stable display order: listening first, then by port, then process —
    /// so the table doesn't reshuffle every refresh.
    static func sorted(_ ports: [ListeningPort]) -> [ListeningPort] {
        ports.sorted {
            if ($0.state == .listen) != ($1.state == .listen) { return $0.state == .listen }
            return ($0.port, $0.process, $0.remoteAddress ?? "") < ($1.port, $1.process, $1.remoteAddress ?? "")
        }
    }

    /// Local ports with more than one distinct owning PID *listening* — the
    /// "two things fighting for the same port" case worth flagging. Returns the
    /// set of conflicted local ports.
    static func conflicts(_ ports: [ListeningPort]) -> Set<Int> {
        var pidsByPort: [Int: Set<Int>] = [:]
        for p in ports where p.state == .listen {
            pidsByPort[p.port, default: []].insert(p.pid)
        }
        return Set(pidsByPort.filter { $0.value.count > 1 }.keys)
    }

    enum Filter: String, CaseIterable { case all, listening, established }

    /// Apply the state filter + a free-text query (port number, process name,
    /// well-known service, or remote host). Pure → unit-tested.
    static func filter(_ ports: [ListeningPort], _ filter: Filter, query: String) -> [ListeningPort] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return ports.filter { p in
            switch filter {
            case .all:         break
            case .listening:   if p.state != .listen { return false }
            case .established: if p.state != .established { return false }
            }
            guard !q.isEmpty else { return true }
            if String(p.port).contains(q) { return true }
            if p.process.lowercased().contains(q) { return true }
            if let svc = PortLookup.service(for: p.port)?.lowercased(), svc.contains(q) { return true }
            if let r = p.remoteAddress?.lowercased(), r.contains(q) { return true }
            return false
        }
    }

    /// Drop exact-duplicate rows — e.g. a process listening on the same port
    /// over IPv4 *and* IPv6 yields two identical entries (same pid/proto/port/
    /// state/peer). They collapse to one; leaving them in gave SwiftUI's ForEach
    /// duplicate ids → phantom gaps + scroll glitches.
    static func deduped(_ ports: [ListeningPort]) -> [ListeningPort] {
        var seen = Set<String>()
        return ports.filter { seen.insert($0.id).inserted }
    }

    enum SortKey: String, CaseIterable { case port, process, peer, down, up }

    /// Sort for the table when the user picks a column. Listening/established
    /// are NOT forced apart here (that's the filter's job) so a bandwidth sort
    /// shows the busiest connections regardless of state.
    static func sorted(_ ports: [ListeningPort], by key: SortKey, ascending: Bool,
                       rates: [Int: NetUsage.Rates]) -> [ListeningPort] {
        // Fold process names once up front for the `.process` sort instead of
        // re-lowercasing both sides inside every O(n log n) comparison. Same
        // pid → same name, so collisions collapse harmlessly.
        let lowered: [Int: String] = key == .process
            ? Dictionary(ports.map { ($0.pid, $0.process.lowercased()) }, uniquingKeysWith: { a, _ in a })
            : [:]
        let s = ports.sorted { a, b in
            switch key {
            case .port:    return a.port != b.port ? a.port < b.port : a.process < b.process
            case .process:
                let pa = lowered[a.pid] ?? a.process.lowercased()
                let pb = lowered[b.pid] ?? b.process.lowercased()
                return pa != pb ? pa < pb : a.port < b.port
            case .peer:    return (a.remoteAddress ?? "") < (b.remoteAddress ?? "")
            case .down:    return (rates[a.pid]?.down ?? 0) < (rates[b.pid]?.down ?? 0)
            case .up:      return (rates[a.pid]?.up ?? 0) < (rates[b.pid]?.up ?? 0)
            }
        }
        return ascending ? s : s.reversed()
    }
}
