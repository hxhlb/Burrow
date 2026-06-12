//
//  Format.swift
//  Burrow
//
//  The shared presentation vocabulary: every number-to-string rule the views
//  render lives here, behind golden tests (FormatTests). Rendered strings are
//  load-bearing — five views and two localizations depend on them — so a
//  change here is a deliberate golden-file edit, never a drive-by.
//

import SwiftUI

enum Fmt {
    static func gb(_ v: Double) -> String {
        v < 10 ? String(format: "%.2f", v) : String(format: "%.0f", v)
    }
    static func bytes(_ b: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(b); var i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        let s = (i == 0) ? "\(Int(v))" : String(format: v < 10 ? "%.2f" : "%.1f", v)
        return "\(s) \(units[i])"
    }
    /// Bytes → binary gigabytes. The only home of the 1_073_741_824 constant.
    static func gib(_ bytes: Double) -> Double { bytes / 1_073_741_824 }
    static func gib(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
    /// Net-rate, footnote form ("↓ 512 KB/s"). Truncates KB/s — pinned;
    /// the tile form below rounds instead. Two renderings, named apart.
    static func rate(_ mbs: Double) -> String {
        mbs < 1 ? "\(Int(mbs * 1024)) KB/s" : String(format: "%.1f MB/s", mbs)
    }
    /// Net-rate, tile form: value and unit rendered separately. The two
    /// screens genuinely differ in MB/s precision (Status 2, HUD 1), so the
    /// caller states it instead of hiding it in a copy-pasted formatter.
    static func rateParts(_ mbs: Double, mbDecimals: Int) -> (value: String, unit: String) {
        mbs < 1 ? (String(format: "%.0f", mbs * 1024), "KB/s")
                : (String(format: "%.\(mbDecimals)f", mbs), "MB/s")
    }
    static func uptime(_ secs: UInt64) -> String {
        let d = secs / 86_400, h = (secs % 86_400) / 3_600, m = (secs % 3_600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    /// Display form of the engine's `hardware.os_version`. Mole already
    /// prefixes it ("macOS 26.5.1"), and views used to prepend their own
    /// "macOS " on top → "macOS macOS 26.5.1" in the HUD chips and the
    /// Status header. One formatter, one prefix: strip any leading
    /// "macOS" (case-insensitive) and re-prepend exactly once. Empty in,
    /// empty out — callers hide the chip entirely.
    static func macOSVersion(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return "" }
        if let r = s.range(of: "macos", options: [.caseInsensitive, .anchored]) {
            s = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
        }
        return s.isEmpty ? "macOS" : "macOS \(s)"
    }
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "MMM d"; return f
    }()
    static func day(_ date: Date) -> String { dayFmt.string(from: date) }
    /// Operation timer: seconds under a minute, then m:ss. Clamps skew to 0s.
    static func elapsed(from start: Date, to now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(start)))
        return s < 60 ? "\(s)s" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Health-score semantics shared by the dashboard and the menu-bar HUD.
/// `tier` is the only threshold switch; label and color derive from it so
/// the two ladders can never drift apart by accident.
enum HealthRating {
    enum Tier { case excellent, good, fair, poor, critical }

    static func tier(_ score: Int) -> Tier {
        switch score {
        case 90...:   return .excellent
        case 75..<90: return .good
        case 60..<75: return .fair
        case 40..<60: return .poor
        default:      return .critical
        }
    }

    static func label(_ score: Int) -> String {
        switch tier(score) {
        case .excellent: return NSLocalizedString("Excellent", comment: "")
        case .good:      return NSLocalizedString("Good", comment: "")
        case .fair:      return NSLocalizedString("Fair", comment: "")
        case .poor:      return NSLocalizedString("Poor", comment: "")
        case .critical:  return NSLocalizedString("Critical", comment: "")
        }
    }

    static func color(_ score: Int) -> Color {
        // Deliberately coarser than the label ladder: excellent and good
        // share green. Pinned by FormatTests.
        switch tier(score) {
        case .excellent, .good: return Brand.green
        case .fair:             return Brand.gold
        case .poor:             return Brand.orange
        case .critical:         return Brand.red
        }
    }
}

/// THE battery / fan accent mapping — the one place it's defined, shared
/// by the Status tiles and the menu-bar HUD so the two surfaces can never
/// disagree (they used to: the HUD showed green while discharging, the
/// Status card amber — it read as random). Pinned by FormatTests.
///
///   Mac battery —  red   = low (≤ 20%),
///                  green = charging / charged / full / on AC,
///                  amber = discharging.
///   Peripherals —  no charging state is reported, so rings use the level
///                  ladder: red ≤ 20, amber ≤ 40, green above.
///   Fan         —  always neutral (Brand.textSecondary): it's read-only
///                  telemetry macOS manages; a state color would imply a
///                  judgement we don't make.
enum PowerAccent {
    /// Mac battery accent from percent + the engine's `status` string
    /// ("charging" / "discharging" / "charged" / "full" / "AC attached").
    static func battery(percent: Double, status: String) -> Color {
        if percent <= 20 { return Brand.red }
        return status.lowercased().contains("discharg") ? Brand.amber : Brand.green
    }

    /// Charge-level ladder for peripheral rings/chips (no state available).
    static func level(_ percent: Int) -> Color {
        if percent <= 20 { return Brand.red }
        if percent <= 40 { return Brand.amber }
        return Brand.green
    }

    /// Fan tiles stay neutral — see the mapping note above.
    static let fan = Brand.textSecondary
}
