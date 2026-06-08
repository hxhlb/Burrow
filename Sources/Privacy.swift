//
//  Privacy.swift
//  Burrow
//
//  Full Disk Access detection and the macOS settings deep-link.
//
//  Burrow shells out to `mo`, which walks system and other-apps' cache
//  directories. On macOS 14+ those reads are TCC-gated ("Burrow would
//  like to access data from other apps") and the prompt is attributed to
//  Burrow — once per protected location, so a single `mo clean --dry-run`
//  or `mo analyze` over the home folder produces a *flood* of dialogs
//  (issue #3).
//
//  The OS-sanctioned remedy is Full Disk Access: once granted, macOS
//  stops gating per-folder reads for this app. We never bypass TCC — we
//  only detect whether we already have access and, if not, point the user
//  at the single switch that grants informed, one-time consent.
//

import Foundation
import AppKit
import SwiftUI

enum Privacy {
    /// Whether to surface the Full Disk Access notice before a scan that
    /// walks protected directories. Pure so it's unit-testable: nag only
    /// when access is missing and the user hasn't already dismissed it.
    static func shouldOfferFullDiskAccess(hasAccess: Bool, dismissed: Bool) -> Bool {
        return !hasAccess && !dismissed
    }

    /// Probe whether Burrow has Full Disk Access by attempting to open an
    /// FDA-gated file. `TCC.db` exists on every Mac and is readable only
    /// with Full Disk Access, so a successful open is the canonical
    /// signal. We open and immediately close — the bytes are never read;
    /// this is a capability probe, not data access. A read that lacks
    /// access fails silently (no prompt), so probing can't itself flood
    /// the user.
    static func hasFullDiskAccess() -> Bool {
        let probes = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/Bookmarks.plist",
        ].map { (NSHomeDirectory() as NSString).appendingPathComponent($0) }
        for path in probes {
            if let fh = FileHandle(forReadingAtPath: path) {
                try? fh.close()
                return true
            }
        }
        return false
    }

    /// Live check combining the access probe with the persisted dismissal.
    static func shouldOfferFullDiskAccessNow() -> Bool {
        shouldOfferFullDiskAccess(hasAccess: hasFullDiskAccess(),
                                  dismissed: Store.fullDiskAccessNoticeDismissed)
    }

    /// Deep-link to System Settings ▸ Privacy & Security ▸ Full Disk Access.
    static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    static func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(fullDiskAccessSettingsURL)
    }
}

/// Dismissible banner shown before scans that walk TCC-protected
/// directories. Surfaces the OS mechanism (Full Disk Access) so the user
/// grants one informed consent instead of fielding a flood of per-folder
/// prompts. Burrow never bypasses TCC — this only points the way.
struct FullDiskAccessNotice: View {
    var accent: Color = Brand.green
    /// Label for the proceed-without-granting action ("Not now" in a
    /// non-blocking banner, "Scan anyway" when it gates a scan).
    var continueLabel: String = "Not now"
    var onOpenSettings: () -> Void = { Privacy.openFullDiskAccessSettings() }
    var onContinue: () -> Void
    /// Optional "don't ask again" — persists the dismissal.
    var onDontAskAgain: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield").font(.system(size: 18)).foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("Skip the macOS permission prompts")
                    .font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                Text("Scanning system & app caches makes macOS ask once per protected folder. Grant Burrow Full Disk Access to scan smoothly — it only reads sizes through Mole and never opens that data itself.")
                    .font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button(action: onOpenSettings) {
                        Text("Open Full Disk Access settings")
                            .font(Brand.sans(11, .semibold)).foregroundStyle(accent)
                    }.buttonStyle(.plain)
                    Button(action: onContinue) {
                        Text(continueLabel).font(Brand.mono(10)).foregroundStyle(Brand.textSecondary)
                    }.buttonStyle(.plain)
                    if let onDontAskAgain {
                        Button(action: onDontAskAgain) {
                            Text("Don't ask again").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(RoundedRectangle(cornerRadius: 13).fill(accent.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(accent.opacity(0.28), lineWidth: 1))
    }
}

/// Blocking gate shown when a flood-prone scan is requested without Full
/// Disk Access. Unlike the soft banner, this STOPS the run — otherwise
/// macOS prompts once per protected folder. Grant FDA once and the
/// prompts stop entirely; "Scan anyway" is the escape hatch (and warns).
struct FullDiskAccessRequired: View {
    var accent: Color
    var onOpenSettings: () -> Void = { Privacy.openFullDiskAccessSettings() }
    var onRecheck: () -> Void
    /// "Scan with admin" — only meaningful where running elevated actually
    /// dodges the prompts (e.g. cache scans). For Downloads/Desktop/Documents,
    /// TCC is keyed on the APP, not the uid, so root doesn't help — pass nil
    /// there and only Full Disk Access is offered.
    var onRunAnyway: (() -> Void)? = nil
    var onCancel: () -> Void

    private var blurb: String {
        onRunAnyway != nil
            ? "This reads system and app caches through Mole. Without Full Disk Access, macOS makes you approve every protected folder — one prompt after another. Grant it once in System Settings and the prompts stop for good. Or run the scan with administrator rights instead: one password, no per-folder asks. Burrow only reads sizes; it never opens that data itself."
            : "Mole scans your Downloads, Desktop and project folders. Without Full Disk Access, macOS makes you approve every protected folder — one prompt after another. Grant it once in System Settings and the prompts stop for good. Burrow only reads sizes; it never opens that data itself."
    }

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            ZStack {
                Circle().fill(accent.opacity(0.15)).frame(width: 64, height: 64)
                Image(systemName: "lock.shield").font(.system(size: 28)).foregroundStyle(accent)
            }
            VStack(spacing: 8) {
                Text("Grant Full Disk Access to scan")
                    .font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text(blurb)
                    .font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }
            VStack(spacing: 12) {
                PillButton(title: "Open Full Disk Access settings") { onOpenSettings() }
                HStack(spacing: 18) {
                    Button("I've granted it — scan") { onRecheck() }
                        .buttonStyle(.plain).font(Brand.sans(12, .semibold)).foregroundStyle(accent)
                    if let onRunAnyway {
                        Button("Scan with admin") { onRunAnyway() }
                            .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.textSecondary)
                    }
                    Button("Cancel") { onCancel() }
                        .buttonStyle(.plain).font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                }
            }
            Spacer(); Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}
