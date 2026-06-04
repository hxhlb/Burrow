//
//  HistoryView.swift
//  Burrow
//
//  History window (Burrow's own value-add over mole.fit): long-range
//  charts over the SQLite history, plus a peak-per-process table. Opened
//  from the HUD's clock button.
//
//  Data path is unchanged from the original: range chip → DB.findRange
//  Sampled (stride-sampled, ≤720 rows) → decode each row to MoleStatus →
//  project to per-chart ChartPoint arrays → SwiftUI Charts. Only the view
//  layer is reskinned into the Brand glass system.
//

import SwiftUI
import Charts

// MARK: - Range chips

struct HistoryRange: Hashable, Identifiable {
    let label: String
    let minutes: Int
    var id: Int { minutes }

    static let all: [HistoryRange] = [
        .init(label: "5m",  minutes: 5),
        .init(label: "1h",  minutes: 60),
        .init(label: "6h",  minutes: 360),
        .init(label: "24h", minutes: 1440),
        .init(label: "7d",  minutes: 10080),
        .init(label: "30d", minutes: 43200),
        .init(label: "90d", minutes: 129600),
    ]
}

// MARK: - Chart series + snapshot bag

struct ChartPoint: Identifiable {
    let id = UUID()
    let time: Date
    let value: Double
}

struct ProcessRow: Identifiable {
    let id = UUID()
    let name: String
    let peakCPU: Double
    let peakMem: Double
}

private struct HistorySnapshot {
    var cpuUsage: [ChartPoint] = []
    var cpuLoad1: [ChartPoint] = []
    var memoryUsed: [ChartPoint] = []
    var memoryPressure: String = "—"
    var diskRead: [ChartPoint] = []
    var diskWrite: [ChartPoint] = []
    var netRx: [ChartPoint] = []
    var netTx: [ChartPoint] = []
    var thermalCPU: [ChartPoint] = []
    var thermalGPU: [ChartPoint] = []
    var healthScore: [ChartPoint] = []

    var topProcesses: [ProcessRow] = []

    var generatedAt: Date = Date()
    var rowCount: Int = 0
    var staleSeconds: Int? = nil

    var windowSince: Date = Date().addingTimeInterval(-3600)
    var windowUntil: Date = Date()
}

// MARK: - Loader (off-main)

private enum HistoryLoader {
    static func load(db: DB, rangeMinutes: Int) -> HistorySnapshot {
        let now = Int(Date().timeIntervalSince1970)
        let since = now - rangeMinutes * 60
        var snap = HistorySnapshot()
        snap.windowSince = Date(timeIntervalSince1970: TimeInterval(since))
        snap.windowUntil = Date(timeIntervalSince1970: TimeInterval(now))

        let rows = db.findRangeSampled(prefix: Sampler.snapshotPrefix,
                                       since: since, until: now,
                                       maxPoints: 720)
        snap.rowCount = rows.count

        let dec = JSONDecoder()
        var peakCPU: [String: Double] = [:]
        var peakMem: [String: Double] = [:]

        for row in rows {
            guard let data = row.json.data(using: .utf8) else { continue }
            guard let s = try? dec.decode(MoleStatus.self, from: data) else { continue }

            let t = Date(timeIntervalSince1970: TimeInterval(row.ts))
            snap.cpuUsage.append(.init(time: t, value: s.cpu.usage))
            snap.cpuLoad1.append(.init(time: t, value: s.cpu.load1))
            snap.memoryUsed.append(.init(time: t, value: s.memory.usedPercent))
            snap.diskRead.append(.init(time: t, value: s.diskIO.readRate))
            snap.diskWrite.append(.init(time: t, value: s.diskIO.writeRate))
            let rx = s.network.reduce(0.0) { $0 + $1.rxRateMbs }
            let tx = s.network.reduce(0.0) { $0 + $1.txRateMbs }
            snap.netRx.append(.init(time: t, value: rx))
            snap.netTx.append(.init(time: t, value: tx))
            if let thermal = s.thermal {
                if thermal.cpuTemp > 0 { snap.thermalCPU.append(.init(time: t, value: thermal.cpuTemp)) }
                if thermal.gpuTemp > 0 { snap.thermalGPU.append(.init(time: t, value: thermal.gpuTemp)) }
            }
            snap.healthScore.append(.init(time: t, value: Double(s.healthScore)))

            for p in (s.topProcesses ?? []) {
                if p.cpu > (peakCPU[p.name] ?? 0)    { peakCPU[p.name] = p.cpu }
                if p.memory > (peakMem[p.name] ?? 0) { peakMem[p.name] = p.memory }
            }
            snap.memoryPressure = s.memory.pressure
        }

        let topByCPU = peakCPU.sorted { $0.value > $1.value }.prefix(15).map(\.key)
        let topByMem = peakMem.sorted { $0.value > $1.value }.prefix(15).map(\.key)
        var seen = Set<String>()
        var rows2: [ProcessRow] = []
        for name in topByCPU + topByMem where seen.insert(name).inserted {
            rows2.append(ProcessRow(name: name,
                                    peakCPU: peakCPU[name] ?? 0,
                                    peakMem: peakMem[name] ?? 0))
        }
        snap.topProcesses = rows2.sorted { $0.peakCPU > $1.peakCPU }

        snap.generatedAt = Date()
        if let latest = rows.last { snap.staleSeconds = max(0, now - latest.ts) }
        return snap
    }
}

// MARK: - Axis style helper

@available(macOS 14.0, *)
private struct AxisStyle {
    let format: Date.FormatStyle
    let desiredCount: Int

    static func forRangeMinutes(_ rangeMinutes: Int) -> AxisStyle {
        switch rangeMinutes {
        case ..<60:            return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(6 * 60):      return AxisStyle(format: .dateTime.hour().minute(), desiredCount: 5)
        case ..<(24 * 60):     return AxisStyle(format: .dateTime.hour(), desiredCount: 6)
        case ..<(8 * 24 * 60): return AxisStyle(format: .dateTime.weekday(.abbreviated).day(), desiredCount: 5)
        case ..<(45 * 24 * 60):return AxisStyle(format: .dateTime.month(.abbreviated).day(), desiredCount: 6)
        default:               return AxisStyle(format: .dateTime.month(.abbreviated), desiredCount: 4)
        }
    }
}

// MARK: - View

struct HistoryView: View {
    let db: DB

    @State private var range: HistoryRange = {
        let m = Store.lastHistoryRangeMinutes
        return HistoryRange.all.first(where: { $0.minutes == m }) ?? HistoryRange.all[1]
    }()
    @State private var snapshot: HistorySnapshot = HistorySnapshot()
    @State private var loading: Bool = false
    @State private var loadGen: Int = 0

    private let autoRefreshTimer = Timer.publish(every: 5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            toolbar.padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
                Rectangle().fill(Brand.hairline).frame(height: 1)
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 13), GridItem(.flexible(), spacing: 13)], spacing: 13) {
                        chartCard("CPU usage", "%", [("usage", snapshot.cpuUsage, Brand.green)])
                        chartCard("CPU load", "1m avg", [("load1", snapshot.cpuLoad1, Brand.orange)])
                        chartCard("Memory", snapshot.memoryPressure.isEmpty ? "% used" : snapshot.memoryPressure,
                                  [("used", snapshot.memoryUsed, Brand.amber)])
                        chartCard("Disk I/O", "MB/s", [("read", snapshot.diskRead, Brand.blue),
                                                       ("write", snapshot.diskWrite, Color(hex: 0x6E8BEA))])
                        chartCard("Network", "MB/s", [("rx", snapshot.netRx, Brand.green),
                                                      ("tx", snapshot.netTx, Color(hex: 0x57C2A5))])
                        chartCard("Thermal", "°C", [("cpu", snapshot.thermalCPU, Brand.red),
                                                    ("gpu", snapshot.thermalGPU, Brand.orange)])
                        chartCard("Health score", "0–100", [("health", snapshot.healthScore, Brand.gold)])
                        topProcessesCard
                    }
                    .padding(16)
                }
                .scrollIndicators(.hidden)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { reload() }
        .onChange(of: range) { _, new in
            Store.lastHistoryRangeMinutes = new.minutes
            reload()
        }
        .onReceive(autoRefreshTimer) { _ in if !loading { reload(silent: true) } }
    }

    private var toolbar: some View {
        HStack(spacing: 12) {
            Text("History").font(Brand.serif(22, .medium)).foregroundStyle(Brand.textPrimary)
            rangePills
            if loading { ProgressView().controlSize(.small) }
            Spacer()
            Text("\(snapshot.rowCount) samples").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            if let s = snapshot.staleSeconds {
                Text("· latest \(s)s ago").font(Brand.mono(10)).foregroundStyle(Brand.textTertiary)
            }
            Button { reload() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Brand.textSecondary)
            }.buttonStyle(.plain).keyboardShortcut("r", modifiers: .command)
        }
    }

    private var rangePills: some View {
        HStack(spacing: 2) {
            ForEach(HistoryRange.all) { r in
                let on = r == range
                Button { range = r } label: {
                    Text(r.label).font(Brand.mono(11, on ? .semibold : .regular))
                        .foregroundStyle(on ? Color.black : Brand.textSecondary)
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background { if on { Capsule().fill(.white) } }
                        .contentShape(Capsule())
                }.buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(Color.black.opacity(0.22)))
        .overlay(Capsule().strokeBorder(Brand.hairline, lineWidth: 1))
    }

    private func chartCard(_ title: String, _ subtitle: String,
                           _ series: [(name: String, points: [ChartPoint], color: Color)]) -> some View {
        let allEmpty = series.allSatisfy { $0.points.isEmpty }
        let style = AxisStyle.forRangeMinutes(range.minutes)
        return GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title.uppercased()).font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(series.first?.color ?? Brand.textSecondary)
                    Text(subtitle).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                if allEmpty {
                    Text("No samples in this window")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    Chart {
                        ForEach(series, id: \.name) { s in
                            ForEach(s.points) { p in
                                LineMark(x: .value("Time", p.time), y: .value("Value", p.value),
                                         series: .value("Series", s.name))
                                    .foregroundStyle(s.color)
                                    .interpolationMethod(.monotone)
                            }
                        }
                    }
                    .chartXScale(domain: snapshot.windowSince...snapshot.windowUntil)
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: style.desiredCount)) { _ in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            AxisValueLabel(format: style.format).foregroundStyle(Brand.textTertiary)
                                .font(Brand.mono(8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks { _ in
                            AxisGridLine().foregroundStyle(Brand.hairline)
                            AxisValueLabel().foregroundStyle(Brand.textTertiary).font(Brand.mono(8))
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    private var topProcessesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("TOP PROCESSES").font(Brand.mono(10, .bold)).tracking(0.7).foregroundStyle(Brand.textSecondary)
                    Text("peak across window").font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
                }
                if snapshot.topProcesses.isEmpty {
                    Text("No processes recorded")
                        .font(Brand.mono(11)).foregroundStyle(Brand.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 170)
                } else {
                    ScrollView {
                        VStack(spacing: 3) {
                            ForEach(snapshot.topProcesses.prefix(18)) { row in
                                HStack {
                                    Text(row.name).font(Brand.sans(11)).foregroundStyle(Brand.textPrimary).lineLimit(1)
                                    Spacer(minLength: 8)
                                    Text(String(format: "%.1f%%", row.peakCPU)).font(Brand.mono(10))
                                        .foregroundStyle(Brand.green).frame(width: 52, alignment: .trailing)
                                    Text(String(format: "%.1f%%", row.peakMem)).font(Brand.mono(10))
                                        .foregroundStyle(Brand.amber).frame(width: 52, alignment: .trailing)
                                }
                            }
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    // MARK: - Load lifecycle

    private func reload(silent: Bool = false) {
        if !silent { loading = true }
        loadGen += 1
        let myGen = loadGen
        let r = self.range
        DispatchQueue.global(qos: .userInitiated).async {
            let snap = HistoryLoader.load(db: self.db, rangeMinutes: r.minutes)
            DispatchQueue.main.async {
                if myGen != self.loadGen { return }
                self.snapshot = snap
                self.loading = false
            }
        }
    }
}
