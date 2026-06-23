//
//  OperationCenter.swift
//  Burrow
//
//  One shared, observable list of "things Burrow is doing" — clean,
//  optimize, analyze scans. The main window's runners report into it, and
//  the menu-bar HUD reads from it, so a job you kicked off in the window
//  is visible from the dropdown (and survives switching tabs). Finished
//  ops linger briefly then drop themselves.
//

import SwiftUI

@MainActor
final class OperationCenter: ObservableObject {
    static let shared = OperationCenter()

    enum Phase: Equatable { case running, done, failed }

    struct Op: Identifiable, Equatable {
        let id: UUID
        var label: String
        var phase: Phase
        var detail: String
        var startedAt: Date
        /// Post a user notification when this op ends — long,
        /// user-initiated work only (real cleans / optimize /
        /// uninstalls; never previews or scans).
        var notifiesOnEnd: Bool = false
    }

    @Published private(set) var ops: [Op] = []

    var hasActivity: Bool { !ops.isEmpty }

    func begin(_ id: UUID, label: String, notifiesOnEnd: Bool = false) {
        if let i = ops.firstIndex(where: { $0.id == id }) {
            ops[i].label = label
            ops[i].phase = .running
            ops[i].detail = ""
            ops[i].notifiesOnEnd = notifiesOnEnd
        } else {
            ops.insert(Op(id: id, label: label, phase: .running, detail: "", startedAt: Date(),
                          notifiesOnEnd: notifiesOnEnd), at: 0)
        }
        if ops.count > 6 { ops = Array(ops.prefix(6)) }
        // Settle notification permission now, while the op runs, so the
        // completion notice can fire the moment it ends (even if the window
        // has been closed by then).
        if notifiesOnEnd { BurrowNotifier.shared.requestAuthorizationIfNeeded() }
    }

    func detail(_ id: UUID, _ text: String) {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        ops[i].detail = trimmed
    }

    func end(_ id: UUID, success: Bool, detail: String = "") {
        guard let i = ops.firstIndex(where: { $0.id == id }) else { return }
        ops[i].phase = success ? .done : .failed
        if !detail.isEmpty { ops[i].detail = detail }
        // Completion notice for opted-in ops (clean / optimize /
        // uninstall). The notifier stays quiet when Burrow is frontmost
        // or the Settings toggle is off.
        if ops[i].notifiesOnEnd {
            BurrowNotifier.shared.operationCompleted(label: ops[i].label, success: success,
                                                     detail: ops[i].detail)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 22) { [weak self] in
            guard let self, let j = self.ops.firstIndex(where: { $0.id == id }) else { return }
            // The runner reuses its id across runs (dry-run → real run):
            // if this op was re-begun inside the linger window, the expiry
            // belongs to the OLD run — a live row must never be removed.
            guard self.ops[j].phase != .running else { return }
            self.ops.remove(at: j)
        }
    }
}
