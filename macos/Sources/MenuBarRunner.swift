//
//  MenuBarRunner.swift
//  Burrow
//
//  A RunCat-style animated menu-bar icon: an icon whose playback speed tracks
//  a chosen metric (faster = busier). The *mechanism* — cycle frame images on
//  the status button via a timer, scaling the interval by load — is
//  re-implemented from scratch (Burrow is MIT); no third-party runner artwork
//  is bundled. The built-in runners are drawn programmatically; users import
//  their own GIF for anything fancier.
//
//  Model lives here (persisted via `Store.runnerConfig`); the actual timer +
//  button image is driven by `StatusBarController`.
//

import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - Config

/// Where the runner's frames come from.
enum RunnerSource: Codable, Equatable {
    case builtIn(String)   // a `RunnerCatalog` id
    case gif(String)       // absolute path to a GIF imported into App Support
}

/// Persisted runner appearance. Whether the runner shows at all is the menu-
/// bar display mode (`.runner` = its own; `.metrics` + `prependToRow` = before
/// the widget row).
struct RunnerConfig: Codable, Equatable {
    var source: RunnerSource = .builtIn(RunnerCatalog.defaultID)
    /// The metric whose usage sets the animation speed.
    var metric: MenuBarMetric = .cpu
    /// Show the metric's value next to the runner.
    var showValue = false
    /// 0.5…2.0 — higher swings the speed more between idle and busy.
    var sensitivity: Double = 1.0
    /// In `.metrics` mode, animate the runner before the widget row.
    var prependToRow = false
}

// MARK: - Frames

/// A decoded animation: frames already sized to the menu-bar height.
struct RunnerFrames {
    let frames: [NSImage]
    var count: Int { frames.count }
    func frame(_ i: Int) -> NSImage? { frames.isEmpty ? nil : frames[i % frames.count] }
}

// MARK: - Built-in catalog (original, drawn programmatically — no bundled art)

enum RunnerCatalog {
    static let defaultID = "pulse"

    struct Builtin: Identifiable { let id: String; let title: String }
    static let all: [Builtin] = [
        .init(id: "pulse",  title: NSLocalizedString("Pulse", comment: "")),
        .init(id: "orbit",  title: NSLocalizedString("Orbit", comment: "")),
        .init(id: "stride", title: NSLocalizedString("Stride", comment: "")),
    ]

    /// Frames for a built-in runner at the given height (square frames).
    static func frames(id: String, height: CGFloat) -> RunnerFrames {
        let n = 12
        let images = (0..<n).map { draw(id: id, phase: CGFloat($0) / CGFloat(n), side: height) }
        return RunnerFrames(frames: images)
    }

    /// One frame at animation phase 0…1. Uses `labelColor` so it adapts to the
    /// light/dark menu bar automatically.
    private static func draw(id: String, phase: CGFloat, side: CGFloat) -> NSImage {
        let s = max(16, side)
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            let c = NSColor.labelColor
            let mid = NSPoint(x: rect.midX, y: rect.midY)
            switch id {
            case "orbit":
                let r = rect.width * 0.30
                let ring = NSBezierPath(ovalIn: NSRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
                c.withAlphaComponent(0.25).setStroke(); ring.lineWidth = 1.5; ring.stroke()
                let a = phase * 2 * .pi
                let p = NSPoint(x: mid.x + cos(a) * r, y: mid.y + sin(a) * r)
                let dot = NSBezierPath(ovalIn: NSRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                c.setFill(); dot.fill()
            case "stride":
                let swing = sin(phase * 2 * .pi) * rect.width * 0.18
                for sgn in [CGFloat(-1), 1] {
                    let leg = NSBezierPath()
                    leg.move(to: NSPoint(x: mid.x, y: rect.midY + rect.height * 0.10))
                    leg.line(to: NSPoint(x: mid.x + sgn * swing, y: rect.minY + rect.height * 0.20))
                    leg.lineWidth = 2; leg.lineCapStyle = .round; c.setStroke(); leg.stroke()
                }
                let body = NSBezierPath(ovalIn: NSRect(x: mid.x - 3, y: rect.midY + rect.height * 0.10, width: 6, height: 6))
                c.setFill(); body.fill()
            default: // "pulse" — concentric expanding rings
                for k in 0..<3 {
                    let t = (phase + CGFloat(k) / 3).truncatingRemainder(dividingBy: 1)
                    let r = rect.width * 0.10 + t * rect.width * 0.30
                    let ring = NSBezierPath(ovalIn: NSRect(x: mid.x - r, y: mid.y - r, width: r * 2, height: r * 2))
                    c.withAlphaComponent(Double(1 - t) * 0.8).setStroke(); ring.lineWidth = 1.5; ring.stroke()
                }
            }
            return true
        }
    }
}

// MARK: - GIF decode + import

enum RunnerGIF {
    /// Decode a GIF into frames resized to `height`. nil on failure.
    /// MUST run off the main thread (disk read + decode).
    static func decode(path: String, height: CGFloat) -> RunnerFrames? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        guard n > 0 else { return nil }
        var out: [NSImage] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            guard let cg = CGImageSourceCreateImageAtIndex(src, i, nil) else { continue }
            out.append(resize(NSImage(cgImage: cg, size: .zero), to: height))
        }
        return out.isEmpty ? nil : RunnerFrames(frames: out)
    }

    private static func resize(_ image: NSImage, to height: CGFloat) -> NSImage {
        let scale = height / max(image.size.height, 1)
        let size = NSSize(width: max(1, image.size.width * scale), height: height)
        let out = NSImage(size: size)
        out.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: NSRect(origin: .zero, size: image.size),
                   operation: .sourceOver, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// Copy an imported GIF into Application Support (so it survives the
    /// original moving/deleting), returning the stored path.
    static func importGIF(from url: URL) -> String? {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Burrow/runners", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("runner.gif")
        try? fm.removeItem(at: dest)
        do { try fm.copyItem(at: url, to: dest); return dest.path } catch { return nil }
    }
}

// MARK: - Engine: frames + speed mapping

/// Holds the runner's frames + the advancing index, and maps a metric value to
/// the frame interval. `StatusBarController` owns the timer and the button.
final class RunnerEngine {
    private(set) var frames = RunnerFrames(frames: [])
    private var index = 0
    private var config = RunnerConfig()

    var hasFrames: Bool { frames.count > 0 }

    /// (Re)load frames for `cfg`. Built-ins are synchronous; a GIF decodes
    /// off-main and lands its frames on the main thread before `completion`.
    func reload(_ cfg: RunnerConfig, height: CGFloat, completion: @escaping () -> Void) {
        config = cfg
        index = 0
        switch cfg.source {
        case .builtIn(let id):
            frames = RunnerCatalog.frames(id: id, height: height)
            completion()
        case .gif(let path):
            DispatchQueue.global(qos: .userInitiated).async {
                let f = RunnerGIF.decode(path: path, height: height)
                    ?? RunnerCatalog.frames(id: RunnerCatalog.defaultID, height: height)
                DispatchQueue.main.async { self.frames = f; completion() }
            }
        }
    }

    /// Advance to and return the next frame (nil if there are none).
    func nextFrame() -> NSImage? {
        guard frames.count > 0 else { return nil }
        defer { index = (index + 1) % frames.count }
        return frames.frame(index)
    }

    /// Frame interval (seconds) for a metric value in 0…100. Faster when
    /// busier, clamped so idle isn't frozen and busy isn't a blur.
    func interval(forUsage usage: Double) -> TimeInterval {
        let u = max(0, min(usage, 100)) / 100
        let base: TimeInterval = 0.20      // idle
        let fastest: TimeInterval = 0.05   // pinned
        let swing = (base - fastest) * config.sensitivity
        return max(fastest, base - swing * u)
    }
}
