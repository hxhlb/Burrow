//
//  TopNav.swift
//  Burrow
//
//  The floating top-centre nav: Burrow mark + five lowercase tool tabs,
//  with Settings (gear) and History (clock) as utilities in the same
//  bar. One navigation model for the whole window — tools and the two
//  Burrow extras are all just `Pane`s.
//

import SwiftUI

struct TopNav: View {
    @Binding var selected: Pane

    var body: some View {
        HStack(spacing: 8) {
            toolGroup
            utilityGroup
        }
    }

    private var toolGroup: some View {
        HStack(spacing: 2) {
            BurrowMark()
                .frame(width: 24, height: 24)
                .padding(.leading, 6)
                .padding(.trailing, 4)
            ForEach(Tool.navOrder) { tool in
                tab(tool)
            }
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private var utilityGroup: some View {
        HStack(spacing: 2) {
            utility("clock.arrow.circlepath", pane: .history)
            utility("gearshape", pane: .settings)
        }
        .padding(4)
        .background(Capsule(style: .continuous).fill(Color.black.opacity(0.24)))
        .overlay(Capsule(style: .continuous).strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func tab(_ tool: Tool) -> some View {
        let isOn = selected == .tool(tool)
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = .tool(tool) }
        } label: {
            Text(tool.label)
                .font(Brand.mono(12, isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Color.black : Brand.textSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background { if isOn { Capsule(style: .continuous).fill(Color.white) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func utility(_ symbol: String, pane: Pane) -> some View {
        let isOn = selected == pane
        return Button {
            withAnimation(.easeOut(duration: 0.16)) { selected = pane }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn ? Color.black : Brand.textSecondary)
                .frame(width: 28, height: 26)
                .background { if isOn { Capsule(style: .continuous).fill(Color.white) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Burrow's mark: a cream disc with a dark burrow mouth (a tunnel arch).
struct BurrowMark: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(Brand.cream)
                Path { p in
                    let cx = s * 0.5
                    let baseY = s * 0.70
                    let r = s * 0.27
                    p.move(to: CGPoint(x: cx - r, y: baseY))
                    p.addArc(center: CGPoint(x: cx, y: baseY), radius: r,
                             startAngle: .degrees(180), endAngle: .degrees(360),
                             clockwise: false)
                    p.closeSubpath()
                }
                .fill(Brand.espresso)
            }
            .frame(width: s, height: s)
        }
    }
}
