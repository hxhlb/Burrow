//
//  ActivityView.swift
//  Burrow
//
//  The Activity pane — Mole's cleanup history (`mo history --json`): past
//  clean / optimize / uninstall / purge sessions, what they removed and
//  what they skipped or failed. Distinct from the metrics "History" pane.
//

import SwiftUI

struct ActivityView: View {
    @StateObject private var model = ActivityModel()

    var body: some View {
        VStack(spacing: 0) {
            header.padding(.horizontal, 20).padding(.top, 4).padding(.bottom, 12)
            Rectangle().fill(Brand.hairline).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { model.loadIfNeeded() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Activity").font(Brand.serif(20, .medium)).foregroundStyle(Brand.textPrimary)
                Text("Recent Mole cleanup sessions").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Spacer()
            Button { model.reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.loading {
            VStack { Spacer(); ProgressView("Reading history…").controlSize(.large)
                .font(Brand.mono(11)); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.sessions.isEmpty {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "clock.badge.questionmark").font(.system(size: 26)).foregroundStyle(Brand.textTertiary)
                Text("No cleanup history yet").font(Brand.mono(12)).foregroundStyle(Brand.textSecondary)
                Text("Run a Clean or Optimize and it'll show up here.").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                Spacer()
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(model.sessions) { SessionRow(session: $0) }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
            .scrollIndicators(.hidden)
        }
    }
}

private struct SessionRow: View {
    let session: HistorySession

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: glyph).font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                    Text(session.command.capitalized).font(Brand.sans(13, .semibold)).foregroundStyle(Brand.textPrimary)
                    if !session.isComplete {
                        Text("incomplete").font(Brand.mono(9)).foregroundStyle(Brand.orange)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Brand.orange.opacity(0.15)))
                    }
                    Spacer()
                    Text(session.startedAt).font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
                }
                HStack(spacing: 14) {
                    stat("\(session.items)", "items")
                    if !session.size.isEmpty, session.size != "0B" { stat(session.size, "freed") }
                    if session.removed > 0 { stat("\(session.removed)", "removed", Brand.green) }
                    if session.skipped > 0 { stat("\(session.skipped)", "skipped", Brand.textSecondary) }
                    if session.failed > 0 { stat("\(session.failed)", "failed", Brand.red) }
                    Spacer()
                }
            }
        }
    }

    private func stat(_ value: String, _ label: String, _ color: Color = Brand.textPrimary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(value).font(Brand.mono(12, .semibold)).foregroundStyle(color)
            Text(label).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
        }
    }

    private var glyph: String {
        switch session.command {
        case "clean":     return "sparkles"
        case "optimize":  return "wand.and.stars"
        case "uninstall": return "trash"
        case "purge":     return "folder.badge.minus"
        case "installer": return "arrow.down.app"
        default:          return "clock.arrow.circlepath"
        }
    }
    private var accent: Color {
        switch session.command {
        case "clean":     return Tool.clean.accent
        case "optimize":  return Tool.optimize.accent
        case "uninstall": return Tool.apps.accent
        default:          return Brand.textSecondary
        }
    }
}

@MainActor
final class ActivityModel: ObservableObject {
    @Published var sessions: [HistorySession] = []
    @Published var loading = false
    private var started = false

    func loadIfNeeded() { guard !started else { return }; started = true; reload() }

    func reload() {
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let parsed = MoleHistory.load()
            Task { @MainActor in
                self.sessions = parsed
                self.loading = false
            }
        }
    }
}
