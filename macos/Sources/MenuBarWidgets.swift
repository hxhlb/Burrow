//
//  MenuBarWidgets.swift
//  Burrow
//
//  The customizable menu-bar metric row (issue #82): the user picks an
//  ordered set of metrics and a display style for each, and the status item
//  renders them next to (or instead of) the Burrow mark.
//
//  Model:
//    * `MenuBarMetric`      — what to show (CPU, RAM, GPU, disk, net, …).
//    * `MenuBarWidgetStyle` — how to show it (value / label / bar / sparkline
//                             / speed / battery), à la a desktop monitor.
//    * `MenuBarColorMode`   — how to colour the value.
//    * `MenuBarItem`        — one configured widget (metric + style + colour),
//                             persisted via `Store.menuBarItems`.
//
//  Rendering: `MenuBarRenderer` draws the whole row into an `NSImage` via a
//  drawing handler (so it re-resolves dynamic colours for light/dark menu
//  bars) which the controller hands to the status button. No custom hit-
//  testing view — the button keeps its existing click/right-click action.
//  All values arrive pre-computed on the main thread from the live feed; the
//  drawing itself is cheap text + a few shapes (deliberately so — the app has
//  a history of main-thread hangs; the menu bar must never add to that).
//

import AppKit
import SwiftUI

// MARK: - Model

/// A metric that can be surfaced in the menu bar.
enum MenuBarMetric: String, Codable, CaseIterable, Identifiable {
    case cpu, memory, gpu, diskUsage, network, diskIO, fan, temperature, battery

    var id: String { rawValue }

    /// Short uppercase tag used by the `labeled` style + the settings picker.
    var label: String {
        switch self {
        case .cpu:         return "CPU"
        case .memory:      return "RAM"
        case .gpu:         return "GPU"
        case .diskUsage:   return "DISK"
        case .network:     return "NET"
        case .diskIO:      return "I/O"
        case .fan:         return "FAN"
        case .temperature: return "TEMP"
        case .battery:     return "BAT"
        }
    }

    /// Human name for the settings list.
    var title: String {
        switch self {
        case .cpu:         return NSLocalizedString("CPU usage", comment: "")
        case .memory:      return NSLocalizedString("Memory usage", comment: "")
        case .gpu:         return NSLocalizedString("GPU usage", comment: "")
        case .diskUsage:   return NSLocalizedString("Disk used", comment: "")
        case .network:     return NSLocalizedString("Network speed", comment: "")
        case .diskIO:      return NSLocalizedString("Disk I/O", comment: "")
        case .fan:         return NSLocalizedString("Fan speed", comment: "")
        case .temperature: return NSLocalizedString("Temperature", comment: "")
        case .battery:     return NSLocalizedString("Battery", comment: "")
        }
    }

    /// SF Symbol for the settings list.
    var glyph: String {
        switch self {
        case .cpu:         return "cpu"
        case .memory:      return "memorychip"
        case .gpu:         return "display"
        case .diskUsage:   return "internaldrive"
        case .network:     return "network"
        case .diskIO:      return "arrow.up.arrow.down"
        case .fan:         return "fanblades"
        case .temperature: return "thermometer.medium"
        case .battery:     return "battery.100"
        }
    }

    /// True for 0–100 metrics (drives bar/threshold colouring).
    var isPercentage: Bool {
        switch self {
        case .cpu, .memory, .gpu, .diskUsage, .battery: return true
        case .network, .diskIO, .fan, .temperature:     return false
        }
    }

    /// Two-channel metrics (down/up, read/write) — eligible for the speed style.
    var isDual: Bool { self == .network || self == .diskIO }

    /// Widget styles offered for this metric in the picker.
    var styles: [MenuBarWidgetStyle] {
        switch self {
        case .cpu, .memory, .gpu:     return [.value, .labeled, .bar, .sparkline]
        case .diskUsage:              return [.value, .labeled, .bar]
        case .network, .diskIO:       return [.value, .labeled, .speed, .sparkline]
        case .fan, .temperature:      return [.value, .labeled]
        case .battery:                return [.value, .labeled, .bar, .battery]
        }
    }

    /// The metrics offered as tiles in the popover grid (issue #82 popup
    /// customization), in display order.
    static let popupGrid: [MenuBarMetric] = [.cpu, .gpu, .memory, .diskUsage, .network, .fan]
}

/// How a metric is rendered in the bar.
enum MenuBarWidgetStyle: String, Codable, CaseIterable, Identifiable {
    case value      // "42%"
    case labeled    // "CPU 42%"
    case bar        // ▮▮▮▯ 42%
    case sparkline  // mini line chart
    case speed      // ↓12M ↑0.4M (two rows)
    case battery    // battery glyph + %

    var id: String { rawValue }

    var title: String {
        switch self {
        case .value:     return NSLocalizedString("Value", comment: "")
        case .labeled:   return NSLocalizedString("Label + value", comment: "")
        case .bar:       return NSLocalizedString("Bar", comment: "")
        case .sparkline: return NSLocalizedString("Sparkline", comment: "")
        case .speed:     return NSLocalizedString("Speed ↓↑", comment: "")
        case .battery:   return NSLocalizedString("Battery glyph", comment: "")
        }
    }
}

/// How the value is coloured. The first four are value-driven; the rest are
/// fixed named colours from the Brand palette (à la a desktop monitor's
/// per-widget colour picker).
enum MenuBarColorMode: String, Codable, CaseIterable, Identifiable {
    case utilization  // green→gold→orange→red by load
    case accent       // Burrow blue
    case mono         // adapts to the menu bar (label colour)
    case pressure     // memory-pressure tinting
    case blue, green, orange, gold, amber, red

    var id: String { rawValue }

    var title: String {
        switch self {
        case .utilization: return NSLocalizedString("By utilization", comment: "")
        case .accent:      return NSLocalizedString("Accent", comment: "")
        case .mono:        return NSLocalizedString("Monochrome", comment: "")
        case .pressure:    return NSLocalizedString("By pressure", comment: "")
        case .blue:        return NSLocalizedString("Blue", comment: "")
        case .green:       return NSLocalizedString("Green", comment: "")
        case .orange:      return NSLocalizedString("Orange", comment: "")
        case .gold:        return NSLocalizedString("Gold", comment: "")
        case .amber:       return NSLocalizedString("Amber", comment: "")
        case .red:         return NSLocalizedString("Red", comment: "")
        }
    }

    /// A fixed colour for the named modes; nil for the value-driven ones.
    var fixedColor: NSColor? {
        switch self {
        case .blue:   return NSColor(Brand.blue)
        case .green:  return NSColor(Brand.green)
        case .orange: return NSColor(Brand.orange)
        case .gold:   return NSColor(Brand.gold)
        case .amber:  return NSColor(Brand.amber)
        case .red:    return NSColor(Brand.red)
        default:      return nil
        }
    }
}

/// The up/down indicator the `speed` style draws.
enum SpeedPictogram: String, Codable, CaseIterable, Identifiable {
    case arrows, dots, none
    var id: String { rawValue }
    var title: String {
        switch self {
        case .arrows: return NSLocalizedString("Arrows", comment: "")
        case .dots:   return NSLocalizedString("Dots", comment: "")
        case .none:   return NSLocalizedString("None", comment: "")
        }
    }
    func symbol(up: Bool) -> String {
        switch self {
        case .arrows: return up ? "↑" : "↓"
        case .dots:   return "•"
        case .none:   return ""
        }
    }
}

/// One configured widget. `id` is stable across reorders/edits. The extra
/// per-widget options (label/value/fill/history/pictogram/units) give the
/// depth a desktop monitor's widget settings offer.
struct MenuBarItem: Codable, Equatable, Identifiable {
    var id = UUID()
    var metric: MenuBarMetric
    var style: MenuBarWidgetStyle
    var color: MenuBarColorMode = .utilization
    /// Prefix the metric's short label (e.g. "CPU") on the bar/sparkline/
    /// speed/battery styles (the `.labeled` style already carries one).
    var showLabel: Bool = false
    /// Draw the trailing numeric on the bar/sparkline/speed/battery styles.
    var showValue: Bool = true
    /// Sparkline: filled area vs. a bare stroke.
    var fill: Bool = true
    /// Sparkline: how many recent points to plot (30/60/90/120).
    var historyPoints: Int = 30
    /// Speed: the up/down indicator.
    var pictogram: SpeedPictogram = .arrows
    /// Speed: append the unit suffix (M/K) to the rate.
    var showUnits: Bool = true

    init(metric: MenuBarMetric, style: MenuBarWidgetStyle, color: MenuBarColorMode = .utilization,
         showLabel: Bool = false, showValue: Bool = true, fill: Bool = true,
         historyPoints: Int = 30, pictogram: SpeedPictogram = .arrows, showUnits: Bool = true) {
        self.metric = metric; self.style = style; self.color = color
        self.showLabel = showLabel; self.showValue = showValue; self.fill = fill
        self.historyPoints = historyPoints; self.pictogram = pictogram; self.showUnits = showUnits
    }

    enum CodingKeys: String, CodingKey {
        case id, metric, style, color, showLabel, showValue, fill, historyPoints, pictogram, showUnits
    }

    /// Tolerant decode: every field falls back to its default, so widget rows
    /// persisted by an earlier version (which only stored id/metric/style/
    /// colour) still load instead of dropping the user's whole row set.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id            = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        metric        = (try? c.decode(MenuBarMetric.self, forKey: .metric)) ?? .cpu
        style         = (try? c.decode(MenuBarWidgetStyle.self, forKey: .style)) ?? .value
        color         = (try? c.decode(MenuBarColorMode.self, forKey: .color)) ?? .utilization
        showLabel     = (try? c.decode(Bool.self, forKey: .showLabel)) ?? false
        showValue     = (try? c.decode(Bool.self, forKey: .showValue)) ?? true
        fill          = (try? c.decode(Bool.self, forKey: .fill)) ?? true
        historyPoints = (try? c.decode(Int.self, forKey: .historyPoints)) ?? 30
        pictogram     = (try? c.decode(SpeedPictogram.self, forKey: .pictogram)) ?? .arrows
        showUnits     = (try? c.decode(Bool.self, forKey: .showUnits)) ?? true
    }

    /// Coerce the style to one the metric actually supports (config can drift
    /// if a metric's offerings change between versions).
    var resolvedStyle: MenuBarWidgetStyle {
        metric.styles.contains(style) ? style : (metric.styles.first ?? .value)
    }

    /// Historical default: a compact CPU + memory pair. Only ever shown once a
    /// user switches the menu bar to `.metrics` (default is the icon).
    static let defaults: [MenuBarItem] = [
        MenuBarItem(metric: .cpu, style: .value),
        MenuBarItem(metric: .memory, style: .value),
    ]
}

// MARK: - Values

/// A main-thread snapshot of everything the row needs to draw, assembled from
/// the live feed by the controller. Optional = unavailable on this Mac (no
/// GPU util, no fans, no battery) → the widget shows "—".
struct MenuBarMetricValues {
    /// Primary number per metric: percent, RPM, °C, or down/read MB/s.
    var primary: [MenuBarMetric: Double] = [:]
    /// Secondary channel for dual metrics: up/write MB/s.
    var secondary: [MenuBarMetric: Double] = [:]
    /// Sparkline series (oldest→newest), already downsampled by the controller.
    var histories: [MenuBarMetric: [Double]] = [:]
    var batteryCharging = false

    func has(_ m: MenuBarMetric) -> Bool { primary[m] != nil }
}

// MARK: - Renderer

/// Draws the configured widget row into an `NSImage`. Pure AppKit, Brand-
/// styled, sized to ~the menu-bar height. Re-runs its drawing handler per
/// appearance so monochrome text tracks the light/dark menu bar.
enum MenuBarRenderer {
    static var height: CGFloat { max(18, NSStatusBar.system.thickness) }

    private static let spacing: CGFloat = 8     // between widgets
    private static let pad: CGFloat = 3         // leading/trailing
    private static let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .bold)
    private static let speedFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .medium)
    private static let barW: CGFloat = 22
    private static let barH: CGFloat = 4
    private static let sparkW: CGFloat = 26
    private static let batteryW: CGFloat = 19
    private static let batteryH: CGFloat = 10

    /// Build the row image. Returns nil when there's nothing to draw (caller
    /// then falls back to the icon).
    static func image(items: [MenuBarItem], values: MenuBarMetricValues) -> NSImage? {
        let cells = items.map { Cell(item: $0, values: values) }
        guard !cells.isEmpty else { return nil }
        let width = pad * 2 + cells.reduce(0) { $0 + $1.width } + spacing * CGFloat(cells.count - 1)
        let h = height
        let image = NSImage(size: NSSize(width: max(width, 1), height: h), flipped: false) { _ in
            var x = pad
            for cell in cells {
                cell.draw(originX: x, height: h)
                x += cell.width + spacing
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // MARK: Threshold colours

    private static func utilization(_ pct: Double) -> NSColor {
        switch pct {
        case 85...:  return NSColor(Brand.red)
        case 65..<85: return NSColor(Brand.orange)
        case 40..<65: return NSColor(Brand.gold)
        default:      return NSColor(Brand.green)
        }
    }

    /// Battery is inverse: low charge is the alarming end.
    private static func batteryColor(_ pct: Double, charging: Bool) -> NSColor {
        if charging { return NSColor(Brand.green) }
        switch pct {
        case ..<10:    return NSColor(Brand.red)
        case 10..<25:  return NSColor(Brand.orange)
        default:       return NSColor(Brand.green)
        }
    }

    static func color(for item: MenuBarItem, value: Double, values: MenuBarMetricValues) -> NSColor {
        if let fixed = item.color.fixedColor { return fixed }   // named colours
        switch item.color {
        case .mono:    return .labelColor
        case .accent:  return NSColor(Brand.blue)
        case .pressure, .utilization:
            if item.metric == .battery { return batteryColor(value, charging: values.batteryCharging) }
            if item.metric.isPercentage { return utilization(value) }
            return NSColor(Brand.blue)
        default:       return .labelColor   // unreachable: named modes handled above
        }
    }

    // MARK: Formatting

    /// Compact rate: MB/s → "12M" / "1.2M" / "640K" / "0". `units:false` drops
    /// the M/K suffix (Speed widget's "Units" toggle).
    static func rate(_ mbs: Double, units: Bool = true) -> String {
        if mbs >= 10 { return String(format: units ? "%.0fM" : "%.0f", mbs) }
        if mbs >= 1  { return String(format: units ? "%.1fM" : "%.1f", mbs) }
        let kb = mbs * 1024
        if kb >= 1 { return String(format: units ? "%.0fK" : "%.0f", kb) }
        return "0"
    }

    /// The single number a value/labeled/bar widget shows for a metric.
    static func valueText(_ m: MenuBarMetric, _ values: MenuBarMetricValues) -> String {
        guard let v = values.primary[m] else { return "—" }
        switch m {
        case .cpu, .memory, .gpu, .diskUsage, .battery:
            return "\(Int(v.rounded()))%"
        case .fan:
            return v > 0 ? "\(Int(v.rounded()))" : "—"
        case .temperature:
            return "\(Int(v.rounded()))°"
        case .network, .diskIO:
            return rate(v + (values.secondary[m] ?? 0))
        }
    }
}

// MARK: - One drawn widget

private struct Cell {
    let item: MenuBarItem
    let values: MenuBarMetricValues
    let style: MenuBarWidgetStyle
    let width: CGFloat

    init(item: MenuBarItem, values: MenuBarMetricValues) {
        self.item = item
        self.values = values
        let style = item.resolvedStyle
        self.style = style
        self.width = Cell.width(item: item, style: style, values: values)
    }

    // MARK: width

    private static func textW(_ s: String, _ font: NSFont) -> CGFloat {
        (s as NSString).size(withAttributes: [.font: font]).width
    }

    private static func width(item: MenuBarItem, style: MenuBarWidgetStyle, values: MenuBarMetricValues) -> CGFloat {
        let valueW = textW(MenuBarRenderer.valueText(item.metric, values), MenuBarRenderer.valueFontPublic)
        // Optional leading label (on the non-text styles) + optional trailing value.
        let labelPrefix = (item.showLabel && style != .value && style != .labeled)
            ? textW(item.metric.label, MenuBarRenderer.labelFontPublic) + 4 : 0
        let valueSuffix = item.showValue ? (5 + valueW) : 0
        switch style {
        case .value:
            return valueW
        case .labeled:
            return textW(item.metric.label, MenuBarRenderer.labelFontPublic) + 4 + valueW
        case .bar:
            return labelPrefix + MenuBarRenderer.barWPublic + valueSuffix
        case .sparkline:
            return labelPrefix + MenuBarRenderer.sparkWPublic + valueSuffix
        case .speed:
            let rx = item.pictogram.symbol(up: false) + MenuBarRenderer.rate(values.primary[item.metric] ?? 0, units: item.showUnits)
            let tx = item.pictogram.symbol(up: true) + MenuBarRenderer.rate(values.secondary[item.metric] ?? 0, units: item.showUnits)
            return labelPrefix + max(textW(rx, MenuBarRenderer.speedFontPublic), textW(tx, MenuBarRenderer.speedFontPublic))
        case .battery:
            return labelPrefix + MenuBarRenderer.batteryWPublic + valueSuffix
        }
    }

    // MARK: draw

    func draw(originX: CGFloat, height: CGFloat) {
        var x = originX
        // Optional leading label for the non-text styles (value/labeled draw
        // their own label inline).
        if item.showLabel, style != .value, style != .labeled {
            let lf = MenuBarRenderer.labelFontPublic
            drawString(item.metric.label, lf, .secondaryLabelColor, at: NSPoint(x: x, y: centeredY(lf, height)))
            x += (item.metric.label as NSString).size(withAttributes: [.font: lf]).width + 4
        }
        switch style {
        case .value:     drawValue(x, height)
        case .labeled:   drawLabeled(x, height)
        case .bar:       drawBar(x, height)
        case .sparkline: drawSparkline(x, height)
        case .speed:     drawSpeed(x, height)
        case .battery:   drawBattery(x, height)
        }
    }

    private var valueColor: NSColor {
        MenuBarRenderer.color(for: item, value: values.primary[item.metric] ?? 0, values: values)
    }

    private func drawString(_ s: String, _ font: NSFont, _ color: NSColor, at p: NSPoint) {
        (s as NSString).draw(at: p, withAttributes: [.font: font, .foregroundColor: color])
    }

    /// Baseline y that vertically centers `font` within the bar height.
    private func centeredY(_ font: NSFont, _ height: CGFloat) -> CGFloat {
        (height - font.ascender + font.descender) / 2
    }

    private func drawValue(_ x: CGFloat, _ h: CGFloat) {
        let f = MenuBarRenderer.valueFontPublic
        drawString(MenuBarRenderer.valueText(item.metric, values), f, valueColor,
                   at: NSPoint(x: x, y: centeredY(f, h)))
    }

    private func drawLabeled(_ x: CGFloat, _ h: CGFloat) {
        let lf = MenuBarRenderer.labelFontPublic
        let label = item.metric.label
        drawString(label, lf, NSColor.secondaryLabelColor, at: NSPoint(x: x, y: centeredY(lf, h)))
        let lw = (label as NSString).size(withAttributes: [.font: lf]).width
        let vf = MenuBarRenderer.valueFontPublic
        drawString(MenuBarRenderer.valueText(item.metric, values), vf, valueColor,
                   at: NSPoint(x: x + lw + 4, y: centeredY(vf, h)))
    }

    private func drawBar(_ x: CGFloat, _ h: CGFloat) {
        let pct = max(0, min((values.primary[item.metric] ?? 0) / 100, 1))
        let bw = MenuBarRenderer.barWPublic, bh = MenuBarRenderer.barHPublic
        let by = (h - bh) / 2
        let track = NSBezierPath(roundedRect: NSRect(x: x, y: by, width: bw, height: bh),
                                 xRadius: bh / 2, yRadius: bh / 2)
        NSColor(Brand.trackFill).setFill(); track.fill()
        if pct > 0 {
            let fill = NSBezierPath(roundedRect: NSRect(x: x, y: by, width: max(bh, bw * pct), height: bh),
                                    xRadius: bh / 2, yRadius: bh / 2)
            valueColor.setFill(); fill.fill()
        }
        if item.showValue {
            let vf = MenuBarRenderer.valueFontPublic
            drawString(MenuBarRenderer.valueText(item.metric, values), vf, valueColor,
                       at: NSPoint(x: x + bw + 5, y: centeredY(vf, h)))
        }
    }

    private func drawSparkline(_ x: CGFloat, _ h: CGFloat) {
        let series = Array((values.histories[item.metric] ?? []).suffix(item.historyPoints))
        let sw = MenuBarRenderer.sparkWPublic
        let inset: CGFloat = 4
        let chartH = h - inset * 2
        let color = valueColor
        if series.count >= 2 {
            let lo = series.min() ?? 0, hi = series.max() ?? 1
            let denom = max(hi - lo, item.metric.isPercentage ? 100 : 0.001)
            let step = sw / CGFloat(series.count - 1)
            func pt(_ i: Int) -> NSPoint {
                let v = (series[i] - lo) / denom
                return NSPoint(x: x + CGFloat(i) * step, y: inset + CGFloat(v) * chartH)
            }
            let line = NSBezierPath(); line.move(to: pt(0))
            for i in 1..<series.count { line.line(to: pt(i)) }
            if item.fill {
                // Filled area under the curve.
                let area = line.copy() as! NSBezierPath
                area.line(to: NSPoint(x: x + sw, y: inset))
                area.line(to: NSPoint(x: x, y: inset))
                area.close()
                color.withAlphaComponent(0.18).setFill(); area.fill()
            }
            color.setStroke(); line.lineWidth = 1; line.stroke()
        } else {
            // Flat baseline when there's no history yet.
            let base = NSBezierPath()
            base.move(to: NSPoint(x: x, y: h / 2)); base.line(to: NSPoint(x: x + sw, y: h / 2))
            color.withAlphaComponent(0.4).setStroke(); base.lineWidth = 1; base.stroke()
        }
        if item.showValue {
            let vf = MenuBarRenderer.valueFontPublic
            drawString(MenuBarRenderer.valueText(item.metric, values), vf, color,
                       at: NSPoint(x: x + sw + 5, y: centeredY(vf, h)))
        }
    }

    private func drawSpeed(_ x: CGFloat, _ h: CGFloat) {
        let f = MenuBarRenderer.speedFontPublic
        let down = item.pictogram.symbol(up: false) + MenuBarRenderer.rate(values.primary[item.metric] ?? 0, units: item.showUnits)
        let up   = item.pictogram.symbol(up: true)  + MenuBarRenderer.rate(values.secondary[item.metric] ?? 0, units: item.showUnits)
        let lineH = f.ascender - f.descender
        let gap: CGFloat = 1
        let topY = h / 2 + gap / 2 - f.descender
        let botY = h / 2 - lineH - gap / 2 - f.descender
        let cDown = item.color == .mono ? NSColor.labelColor : (item.color.fixedColor ?? NSColor(Brand.blue))
        let cUp   = item.color == .mono ? NSColor.secondaryLabelColor : (item.color.fixedColor ?? NSColor(Brand.green))
        drawString(down, f, cDown, at: NSPoint(x: x, y: topY))
        drawString(up, f, cUp, at: NSPoint(x: x, y: botY))
    }

    private func drawBattery(_ x: CGFloat, _ h: CGFloat) {
        let pct = max(0, min((values.primary[item.metric] ?? 0) / 100, 1))
        let bw = MenuBarRenderer.batteryWPublic, bh = MenuBarRenderer.batteryHPublic
        let by = (h - bh) / 2
        let bodyW = bw - 2  // leave room for the cap nub
        let body = NSBezierPath(roundedRect: NSRect(x: x, y: by, width: bodyW, height: bh),
                                xRadius: 2, yRadius: 2)
        NSColor.secondaryLabelColor.setStroke(); body.lineWidth = 1; body.stroke()
        // Cap nub.
        let cap = NSBezierPath(rect: NSRect(x: x + bodyW, y: by + bh * 0.3, width: 2, height: bh * 0.4))
        NSColor.secondaryLabelColor.setFill(); cap.fill()
        // Fill proportional to charge.
        let color = MenuBarRenderer.color(for: item, value: values.primary[item.metric] ?? 0, values: values)
        let inset: CGFloat = 1.5
        let fillW = max(0, (bodyW - inset * 2) * pct)
        if fillW > 0 {
            let fill = NSBezierPath(rect: NSRect(x: x + inset, y: by + inset, width: fillW, height: bh - inset * 2))
            color.setFill(); fill.fill()
        }
        if item.showValue {
            let vf = MenuBarRenderer.valueFontPublic
            drawString(MenuBarRenderer.valueText(item.metric, values), vf, color,
                       at: NSPoint(x: x + bw + 4, y: centeredY(vf, h)))
        }
    }
}

// MARK: - Layout-constant accessors
//
// `Cell` lives in this file but outside the `MenuBarRenderer` enum, so expose
// the private metrics it needs through thin public shims (keeps the tuning
// values in one place).
extension MenuBarRenderer {
    static var valueFontPublic: NSFont { valueFont }
    static var labelFontPublic: NSFont { labelFont }
    static var speedFontPublic: NSFont { speedFont }
    static var barWPublic: CGFloat { barW }
    static var barHPublic: CGFloat { barH }
    static var sparkWPublic: CGFloat { sparkW }
    static var batteryWPublic: CGFloat { batteryW }
    static var batteryHPublic: CGFloat { batteryH }
}
