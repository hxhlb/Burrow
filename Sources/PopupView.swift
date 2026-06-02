//
//  PopupView.swift
//  Burrow
//
//  Menu-bar popover. Reads the latest snapshot from the Sampler's
//  in-memory mirror (no DB hit per redraw) and refreshes every second
//  so the freshness label stays current. Bottom row has buttons that
//  open the History / Cleanup / Settings windows via AppDelegate.
//
//  Intentionally compact: one screen, one summary, one row of actions.
//  Deeper UI lives in the dedicated windows.
//

import SwiftUI

struct PopupView: View {
    @ObservedObject private var model: PopupModel
    private weak var delegate: AppDelegate?

    init(sampler: Sampler, delegate: AppDelegate) {
        self.model = PopupModel(sampler: sampler)
        self.delegate = delegate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if let snap = model.snapshot {
                summary(snap)
            } else {
                ContentUnavailableView(
                    "Waiting for first sample",
                    systemImage: "antenna.radiowaves.left.and.right.slash",
                    description: Text("Burrow runs `mo status --json` at the configured cadence. The first row appears within one tick of launch.")
                )
                .frame(maxWidth: .infinity, alignment: .center)
            }

            Divider()
            actionRow
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 320)
        .onReceive(model.tickPublisher) { _ in model.refresh() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis").foregroundStyle(.tint)
            Text("Burrow").font(.headline)
            Spacer()
            Text(model.freshnessLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private func summary(_ s: MoleStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            row(label: "CPU",
                value: String(format: "%.1f %%", s.cpu.usage),
                detail: "load \(String(format: "%.2f", s.cpu.load1))")
            row(label: "Memory",
                value: String(format: "%.1f %%", s.memory.usedPercent),
                detail: s.memory.pressure)
            row(label: "Disk",
                value: String(format: "R %.1f / W %.1f MB/s",
                              s.diskIO.readRate, s.diskIO.writeRate),
                detail: nil)
            if let thermal = s.thermal, thermal.cpuTemp > 0 {
                row(label: "Temp",
                    value: String(format: "%.0f °C", thermal.cpuTemp),
                    detail: thermal.fanSpeed > 0 ? "fan \(thermal.fanSpeed)" : nil)
            }
            row(label: "Health",
                value: "\(s.healthScore)",
                detail: s.healthScoreMsg.isEmpty ? nil : s.healthScoreMsg)
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private func row(label: String, value: String, detail: String?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
            Text(value)
            Spacer()
            if let d = detail { Text(d).foregroundStyle(.tertiary) }
        }
    }

    private var actionRow: some View {
        // Four-up in one row would crowd at 320 px; split into two rows
        // so each button keeps a comfortable hit target.
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                actionButton(title: "History", symbol: "chart.bar.xaxis") {
                    self.delegate?.openHistory()
                }
                actionButton(title: "Disk Map", symbol: "square.grid.3x3.fill") {
                    self.delegate?.openDiskMap()
                }
            }
            HStack(spacing: 8) {
                actionButton(title: "Cleanup", symbol: "trash") {
                    self.delegate?.openCleanup()
                }
                actionButton(title: "Settings", symbol: "gear") {
                    self.delegate?.openSettings()
                }
            }
        }
    }

    private func actionButton(title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
    }

    private var footer: some View {
        HStack {
            Text("MCP @ 127.0.0.1:\(Store.queryServerPort)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            Button("Quit", action: { NSApp.terminate(nil) })
                .keyboardShortcut("q", modifiers: .command)
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
    }
}

// MARK: - Tick driver

private final class PopupModel: ObservableObject {
    @Published var snapshot: MoleStatus?
    @Published var freshnessLabel: String = "—"

    let tickPublisher = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private let sampler: Sampler

    init(sampler: Sampler) {
        self.sampler = sampler
        self.refresh()
    }

    func refresh() {
        self.snapshot = self.sampler.lastSnapshot
        if let last = self.sampler.lastSampleAt {
            let elapsed = Int(Date().timeIntervalSince(last))
            self.freshnessLabel = "\(elapsed)s ago"
        } else {
            self.freshnessLabel = "—"
        }
    }
}
