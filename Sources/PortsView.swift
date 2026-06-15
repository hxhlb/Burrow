//
//  PortsView.swift
//  Burrow
//
//  Listening-port inspector pane (roadmap C.10): the GUI of `lsof -i` + kill.
//  Lists PortEnumerator.listening() with a confirm-gated Quit (SIGTERM) on the
//  user's own processes only (PortInspector.isKillable); root/other-user
//  sockets are shown read-only.
//
//  NOTE (hand-test): native enumeration + a real kill — verify the list vs
//  `lsof -i -P` and that Quit only targets your own processes.
//

import SwiftUI
import Darwin

struct PortsView: View {
    @State private var ports: [ListeningPort] = []
    @State private var killTarget: ListeningPort?
    private let uid = Int(getuid())

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text(NSLocalizedString("Listening ports", comment: "")).font(.title2.bold())
                ForEach(Array(ports.enumerated()), id: \.offset) { _, p in
                    HStack(spacing: 12) {
                        Text("\(p.port)").font(.body.monospacedDigit().weight(.bold))
                            .frame(width: 64, alignment: .leading)
                        Text(p.proto).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 36, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(p.process).font(.headline)
                            Text("pid \(p.pid)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if PortInspector.isKillable(p, currentUID: uid) {
                            Button(NSLocalizedString("Quit", comment: "")) { killTarget = p }
                                .buttonStyle(.bordered)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .task { reload() }
        .confirmationDialog(
            NSLocalizedString("Quit this process?", comment: ""),
            isPresented: Binding(get: { killTarget != nil },
                                 set: { if !$0 { killTarget = nil } }),
            presenting: killTarget
        ) { p in
            Button(NSLocalizedString("Quit", comment: ""), role: .destructive) {
                _ = kill(pid_t(p.pid), SIGTERM)
                reload()
            }
            Button(NSLocalizedString("Cancel", comment: ""), role: .cancel) {}
        } message: { p in
            Text("\(p.process) (pid \(p.pid)) — port \(p.port)")
        }
    }

    private func reload() {
        Task.detached(priority: .userInitiated) {
            let found = PortEnumerator.listening()
            await MainActor.run { ports = found }
        }
    }
}
