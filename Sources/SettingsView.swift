//
//  SettingsView.swift
//  Burrow
//
//  Settings window (opened from the HUD's gear). Same contract as before
//  — reads/writes the typed `Store`, surfaces `Maintenance` status, and
//  notes which changes need a relaunch — but reskinned into the Brand
//  glass system to match the rest of the app. Hosted in a translucent
//  utility window by AppDelegate.
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @State private var sampleIntervalSeconds: Int = Store.sampleIntervalSeconds
    @State private var retentionDays: Int = Store.retentionDays
    @State private var autoVacuum: Bool = Store.autoVacuum
    @State private var queryServerEnabled: Bool = Store.queryServerEnabled
    @State private var dbSizeText: String = "—"
    @State private var lastMaintenanceText: String = "—"
    @State private var moleVersion: String = "—"
    @State private var moleUpdating = false

    /// Wired by AppDelegate; the only consumer is "Run maintenance now".
    var onRunMaintenance: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                    Text("Settings").font(Brand.serif(24, .medium)).foregroundStyle(Brand.textPrimary)

                    section("Storage", "internaldrive") {
                        infoRow("Currently using", dbSizeText)
                        infoRow("Last maintenance", lastMaintenanceText)
                        HStack {
                            Spacer()
                            PillButton(title: "Run maintenance now", filled: false) {
                                onRunMaintenance?(); refreshStatusLabels()
                            }
                        }
                        footnote("History lives at ~/Library/Application Support/Burrow/burrow.db. Rows past the retention window are pruned hourly.")
                    }

                    section("Mole engine", "shippingbox") {
                        infoRow("Version", moleVersion)
                        HStack {
                            Spacer()
                            if moleUpdating { ProgressView().controlSize(.small).padding(.trailing, 4) }
                            PillButton(title: moleUpdating ? "Updating…" : "Update Mole", filled: false) { updateMole() }
                        }
                        footnote("Runs `mo update` to update the Mole CLI engine Burrow drives. This is separate from Burrow's own app updates. If it needs a password or a confirmation it can't show here, run `mo update` in a terminal instead.")
                    }

                    section("History retention", "calendar") {
                        pickerRow("Keep history for", selection: $retentionDays,
                                  options: [(1, "1 day"), (7, "7 days"), (14, "14 days"),
                                            (30, "30 days"), (90, "90 days"), (180, "180 days"), (365, "1 year")]) {
                            Store.retentionDays = $0
                        }
                        toggleRow("Vacuum DB after large prunes", isOn: $autoVacuum) { Store.autoVacuum = $0 }
                    }

                    section("Sampling", "waveform.path.ecg") {
                        pickerRow("Sample every", selection: $sampleIntervalSeconds,
                                  options: [(5, "5 sec"), (15, "15 sec"), (30, "30 sec"),
                                            (60, "60 sec"), (120, "2 min"), (300, "5 min")]) {
                            Store.sampleIntervalSeconds = $0
                        }
                        footnote("Burrow runs `mo status --json` at this cadence. 60 s is plenty for charts; tighter intervals give finer detail at the cost of more subprocess churn.")
                    }

                    section("MCP query server", "antenna.radiowaves.left.and.right") {
                        toggleRow("Enable MCP query server", isOn: $queryServerEnabled) { Store.queryServerEnabled = $0 }
                        infoRow("Endpoint", "127.0.0.1:\(Store.queryServerPort)")
                        footnote("Toggle + port changes take effect after a relaunch. Exposes /health, /info, /snapshot, /metrics over localhost, plus the `Burrow --mcp` stdio server for Claude Code.")
                    }
                }
                .padding(22)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { refreshStatusLabels(); loadMoleVersion() }
    }

    // MARK: - Mole engine

    private func loadMoleVersion() {
        DispatchQueue.global(qos: .userInitiated).async {
            let v = MoleCLI.version()
            DispatchQueue.main.async { moleVersion = v.map { "v\($0)" } ?? "not found" }
        }
    }

    private func updateMole() {
        guard !moleUpdating else { return }
        moleUpdating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = try? MoleCLI.run(args: ["update"], timeout: 600)
            let newVersion = MoleCLI.version()
            DispatchQueue.main.async {
                moleUpdating = false
                if let v = newVersion { moleVersion = "v\(v)" }
                let ok = (res?.exitCode ?? 1) == 0
                let alert = NSAlert()
                alert.messageText = ok ? "Mole is up to date" : "Update didn't complete"
                alert.informativeText = ok
                    ? "Now on \(moleVersion)."
                    : (res?.stderr.isEmpty == false ? String(res!.stderr.prefix(300))
                                                    : "`mo update` exited non-zero. Try running it in a terminal.")
                alert.runModal()
            }
        }
    }

    // MARK: - Section + row helpers

    private func section<C: View>(_ title: String, _ glyph: String, @ViewBuilder content: @escaping () -> C) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: title, glyph: glyph, color: Brand.textSecondary)
                content()
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textSecondary)
            Spacer()
            Text(value).font(Brand.mono(11)).foregroundStyle(Brand.textPrimary)
        }
    }

    private func footnote(_ text: String) -> some View {
        Text(NSLocalizedString(text, comment: "")).font(Brand.mono(9)).foregroundStyle(Brand.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>, onChange: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: isOn) {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
        }
        .toggleStyle(.switch)
        .tint(Brand.green)
        .onChange(of: isOn.wrappedValue) { _, n in onChange(n) }
    }

    private func pickerRow(_ label: String, selection: Binding<Int>,
                           options: [(Int, String)], onChange: @escaping (Int) -> Void) -> some View {
        HStack {
            Text(NSLocalizedString(label, comment: "")).font(Brand.sans(12)).foregroundStyle(Brand.textPrimary)
            Spacer()
            Picker("", selection: selection) {
                ForEach(options, id: \.0) { Text(NSLocalizedString($0.1, comment: "")).tag($0.0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Brand.textSecondary)
            .fixedSize()
            .onChange(of: selection.wrappedValue) { _, n in onChange(n) }
        }
    }

    // MARK: - Status labels

    private func refreshStatusLabels() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appendingPathComponent("Burrow", isDirectory: true)
        var total: Int64 = 0
        if let enumerator = FileManager.default.enumerator(at: support,
                                                           includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                    total += Int64(size)
                }
            }
        }
        self.dbSizeText = Fmt.bytes(total)

        if let last = AppDelegate.shared?.maintenance?.lastRunAt {
            let delta = Int(Date().timeIntervalSince(last))
            self.lastMaintenanceText = String(format: NSLocalizedString("%ds ago · pruned %d rows", comment: ""),
                                              delta, AppDelegate.shared?.maintenance?.lastPruneDeleted ?? 0)
        } else {
            self.lastMaintenanceText = NSLocalizedString("not yet run", comment: "")
        }
    }
}
