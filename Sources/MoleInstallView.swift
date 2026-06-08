//
//  MoleInstallView.swift
//  Burrow
//
//  Guided onboarding when the `mo` engine is missing. Burrow can't run
//  without it, but rather than quit with a dead-end alert we show the
//  exact install command (copyable) and a Recheck button — we never run
//  an installer on the user's behalf. Once `mo` is found, `onReady` fires
//  and the app continues its normal startup.
//

import SwiftUI
import AppKit

struct MoleInstallView: View {
    /// Called when a Recheck finds `mo` on PATH — the app proceeds.
    var onReady: () -> Void

    @State private var checking = false
    @State private var stillMissing = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Mole engine required", systemImage: "shippingbox")
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text("Burrow is a GUI for the Mole CLI (`mo`) — it does the scanning and cleanup. Install it, then Recheck.")
                    .font(Brand.sans(13)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("WITH HOMEBREW").font(Brand.mono(9, .bold)).tracking(0.6).foregroundStyle(Brand.textTertiary)
                HStack {
                    Text(MoleCLI.installCommand).font(Brand.mono(12)).foregroundStyle(Brand.textPrimary)
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(MoleCLI.installCommand, forType: .string)
                        copied = true
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(Brand.mono(10)).foregroundStyle(Brand.green)
                    }.buttonStyle(.plain)
                }
                .padding(11)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.25)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Brand.hairline, lineWidth: 1))

                Button { NSWorkspace.shared.open(MoleCLI.repoURL) } label: {
                    Text("No Homebrew? Other install options →")
                        .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                }.buttonStyle(.plain)
            }

            if stillMissing {
                Text("Still not finding `mo` on PATH. If you just installed it, open a new terminal first, or relaunch Burrow.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            HStack(spacing: 12) {
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                PillButton(title: checking ? "Checking…" : "Recheck") { recheck() }
            }
        }
        .padding(22)
        .frame(width: 460, height: 320)
        .background(Color(hex: 0x14130E))
        .environment(\.colorScheme, .dark)
    }

    private func recheck() {
        checking = true; stillMissing = false; copied = false
        DispatchQueue.global(qos: .userInitiated).async {
            let found = MoleCLI.findExecutable() != nil
            DispatchQueue.main.async {
                checking = false
                if found { onReady() } else { stillMissing = true }
            }
        }
    }
}
