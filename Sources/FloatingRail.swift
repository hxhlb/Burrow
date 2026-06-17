//
//  FloatingRail.swift
//  Burrow
//
//  The left-edge navigation: a floating, rounded rail of icon buttons in
//  place of a top tab bar. The Burrow mark (Monitor — the live dashboard)
//  sits at the top, the tools below — each lighting up in its own accent
//  when active — and Settings is pinned to the foot. Hovering a button
//  flies out its label, so the icons are never cryptic. Same single `Pane`
//  model as the rest of the window.
//

import SwiftUI

struct FloatingRail: View {
    @Binding var selected: Pane

    var body: some View {
        VStack(spacing: 8) {
            RailButton(label: NSLocalizedString("Monitor", comment: ""),
                       isOn: selected == .home, accent: nil, gradient: false,
                       action: { select(.home) }) {
                BurrowMark().frame(width: 24, height: 24)
            }

            Rectangle().fill(Brand.hairline)
                .frame(width: 22, height: 1)
                .padding(.vertical, 2)

            ForEach(Tool.navOrder) { tool in
                let on = selected == .tool(tool)
                RailButton(label: tool.title, isOn: on, accent: tool.accent, gradient: true,
                           action: { select(.tool(tool)) }) {
                    Image(systemName: tool.glyph)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(on ? Brand.onAccent : Brand.textSecondary)
                }
            }

            Spacer(minLength: 8)

            RailButton(label: NSLocalizedString("Settings", comment: ""),
                       isOn: selected == .settings, accent: Brand.accent, gradient: false,
                       action: { select(.settings) }) {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(selected == .settings ? Brand.onAccent : Brand.textSecondary)
            }
        }
        .padding(8)
        .frame(width: 60)
        .frame(maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Brand.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Brand.hairline, lineWidth: 1)
        )
    }

    private func select(_ pane: Pane) {
        withAnimation(.easeOut(duration: 0.16)) { selected = pane }
    }
}

/// One rail button: an icon tile that fills with `accent` (a gradient for
/// tools, a flat fill for the primary) when selected, a neutral inset tile
/// when `accent` is nil (the Monitor mark), and flies out its label on hover.
private struct RailButton<Icon: View>: View {
    let label: String
    let isOn: Bool
    /// nil → neutral inset active style (Monitor); otherwise fill with this accent.
    let accent: Color?
    let gradient: Bool
    let action: () -> Void
    @ViewBuilder var icon: () -> Icon

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: 44, height: 44)
                .background { activeBackground }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .overlay(alignment: .leading) { flyout }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.16), value: isOn)
    }

    @ViewBuilder private var activeBackground: some View {
        if isOn {
            if let accent {
                if gradient {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(LinearGradient(colors: [accent, accent.opacity(0.78)],
                                             startPoint: .top, endPoint: .bottom))
                } else {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(accent)
                }
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Brand.cardFillHover)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Brand.textSecondary.opacity(0.45), lineWidth: 1))
            }
        }
    }

    @ViewBuilder private var flyout: some View {
        if hovering {
            Text(label)
                .font(Brand.mono(11, .medium))
                .foregroundStyle(Brand.textPrimary)
                .fixedSize()
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule(style: .continuous).fill(Brand.baseSoft))
                .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 8, y: 2)
                .offset(x: 54)
                .allowsHitTesting(false)
                .transition(.opacity)
                .zIndex(20)
        }
    }
}
