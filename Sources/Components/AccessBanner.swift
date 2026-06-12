//
//  AccessBanner.swift
//  Burrow / Components
//
//  The ambient "Full Disk Access is off" state, demoted from blocking
//  gate cards to one bottom-anchored banner over the whole window. It
//  informs — the page behind stays fully usable. RootView mounts it
//  once and re-probes access whenever the app activates, so granting
//  FDA in System Settings dismisses it without a click.
//

import SwiftUI

struct AccessBanner: View {
    var onOpenSettings: () -> Void = { Privacy.openFullDiskAccessSettings() }
    var onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Brand.amber)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Brand.amber.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Full Disk Access is off")
                    .font(Brand.sans(12, .semibold)).foregroundStyle(Brand.textPrimary)
                Text("Without it, Burrow can't reach most system caches.")
                    .font(Brand.sans(11)).foregroundStyle(Brand.textSecondary)
            }
            Spacer(minLength: 14)
            Button(action: onOpenSettings) {
                Text("Open Settings")
                    .font(Brand.sans(11, .semibold)).foregroundStyle(Brand.textPrimary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Brand.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(NSLocalizedString("Dismiss", comment: ""))
            .accessibilityLabel(NSLocalizedString("Dismiss", comment: ""))
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: 0x1A1812).opacity(0.96))
        )
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Brand.amber.opacity(0.25), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(NSLocalizedString("Full Disk Access is off", comment: ""))
    }
}
