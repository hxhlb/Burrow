//
//  ConnectivityView.swift
//  Burrow
//
//  "Get Online" pane (plan §2.2): the travel-Wi-Fi rescue surface. Runs the
//  device-side checks (VPN / proxy / custom DNS / Private Relay) plus a
//  captive-portal + reachability probe, then offers a one-tap "Open Login Page"
//  and a Settings deep-link per blocker. Detection is best-effort and honest —
//  Private Relay has no public API, so that row says "check manually."
//
//  NOTE (hand-test): the probes are network/system I/O (URLSession, scutil,
//  CFNetwork) and can't run in CI — verify on a real hotspot.
//

import SwiftUI
import AppKit

struct ConnectivityView: View {
    var isActive: Bool = true

    @State private var checks: [Connectivity.Check] = []
    @State private var iface: String?
    @State private var loading = false
    @State private var loaded = false
    @State private var actionBusy: Connectivity.Fix?
    @State private var actionResult: String?

    private var accent: Color { Tool.status.accent }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                actionsCard
                ForEach(checks) { checkRow($0) }
                if loaded, checks.isEmpty {
                    Text(NSLocalizedString("Couldn't run the checks.", comment: ""))
                        .font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .onAppear { if isActive, !loaded { reload() } }
        .onChange(of: isActive) { _, now in if now, !loaded { reload() } }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text(NSLocalizedString("Get Online", comment: ""))
                    .font(Brand.serif(26, .medium)).foregroundStyle(Brand.textPrimary)
                HStack(spacing: 7) {
                    if loading {
                        ProgressView().controlSize(.small).tint(accent)
                        Text(NSLocalizedString("Checking your connection…", comment: ""))
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    } else {
                        Text(NSLocalizedString("What might be blocking the login page.", comment: ""))
                            .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                }
            }
            Spacer()
            Button { reload() } label: {
                Label(NSLocalizedString("Re-check", comment: ""), systemImage: "arrow.clockwise")
                    .font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
            }
            .buttonStyle(.plain).disabled(loading).opacity(loading ? 0.4 : 1)
        }
    }

    private var actionsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                Eyebrow(text: "Fixes", glyph: "wrench.and.screwdriver", color: accent)
                Text(NSLocalizedString("Force the login page open, or clear the two things that most often wedge a hotspot connection. Burrow runs these for you (one password) — it doesn't just point at Settings.", comment: ""))
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    PillButton(title: "Open Login Page") { NSWorkspace.shared.open(Connectivity.probeURL) }
                    fixButton("Flush DNS", .flushDNS)
                    fixButton("Renew DHCP", .renewDHCP)
                    Spacer()
                }
                if let msg = actionResult {
                    Text(msg).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                }
            }
        }
    }

    @ViewBuilder private func fixButton(_ title: String, _ fix: Connectivity.Fix) -> some View {
        if actionBusy == fix {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(title).font(Brand.sans(12)).foregroundStyle(Brand.textTertiary)
            }
        } else {
            PillButton(title: title, filled: false) { runFix(fix) }
                .disabled(actionBusy != nil)
                .opacity(actionBusy != nil ? 0.4 : 1)
        }
    }

    private func runFix(_ fix: Connectivity.Fix) {
        actionBusy = fix
        actionResult = nil
        let iface = self.iface
        Task.detached(priority: .userInitiated) {
            let r = Connectivity.run(fix, interface: iface)
            await MainActor.run {
                actionBusy = nil
                actionResult = r.message
                if r.ok { reload() }   // re-check after a successful fix
            }
        }
    }

    private func checkRow(_ c: Connectivity.Check) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: Self.glyph(c.status))
                    .font(.system(size: 15)).foregroundStyle(Self.color(c.status))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(c.title).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    Text(c.detail).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let hint = c.settingsHint {
                        Text(hint).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                    }
                }
                Spacer()
                if c.settingsHint != nil {
                    Button { openSystemSettings() } label: {
                        Text(NSLocalizedString("Open Settings", comment: ""))
                            .font(Brand.sans(11, .semibold)).foregroundStyle(accent)
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private static func glyph(_ s: Connectivity.Status) -> String {
        switch s {
        case .ok:      return "checkmark.circle.fill"
        case .warn:    return "exclamationmark.triangle.fill"
        case .blocked: return "xmark.octagon.fill"
        case .info:    return "info.circle.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }
    private static func color(_ s: Connectivity.Status) -> Color {
        switch s {
        case .ok:      return Brand.green
        case .warn:    return Brand.amber
        case .blocked: return Brand.red
        case .info:    return Brand.blue
        case .unknown: return Brand.textTertiary
        }
    }

    private func openSystemSettings() {
        // Settings layouts shift between macOS versions, so we open System
        // Settings and let the per-row hint say where — reliable over fragile
        // deep-link URLs.
        if let url = URL(string: "x-apple.systempreferences:") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reload() {
        loading = true
        Task {
            let result = await Connectivity.probeAll()
            checks = result.checks
            iface = result.interface
            loading = false
            loaded = true
        }
    }
}
