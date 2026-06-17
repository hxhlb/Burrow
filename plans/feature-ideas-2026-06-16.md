# Burrow — consolidated feature backlog & fixes (2026-06-16)

Single source of truth for everything raised across the 2026-06-16 session:
hand-test regressions, reworks, and net-new feature tracks pulled from
reference apps (Hotspot Guide, rustnet/bandwhich/portpilot/whatportis,
brew-browser, Updatest). Effort: S/M/L. Every item is **compile-verifiable
only on my side — Henry hand-tests before anything is called done.**

Guardrails (apply to every track):
- **No cloning.** brew-browser (MIT), Updatest (MAS), Hotspot Guide (MAS) are
  peers' shipping apps. Capabilities are generic (brew/OSV/SecStaticCode/lsof) —
  build in Burrow's own idiom, not their layouts/copy.
- **Local-first.** No crowd-share network, no telemetry phone-home. Any network
  feature is opt-in + respects a master Offline switch.
- **GeoIP DB licensing** is a separate landmine from tool code (MaxMind GeoLite2
  EULA is restrictive; prefer DB-IP Lite / IP2Location-LITE if we bundle).

---

## P0 — Bugs I marked "done" that aren't (root-caused in code)

### 0.1 Chart drag does nothing (still) — S
- **Root cause:** `window.isMovableByWindowBackground = true`
  (AppDelegate.swift:257, :323). AppKit starts a window-drag on mouse-down over
  non-interactive content *before* SwiftUI's `DragGesture(minimumDistance:4)`
  engages. `.highPriorityGesture` only outranks other SwiftUI gestures — it
  cannot beat AppKit window-drag. My earlier fix was structurally incapable of working.
- **Fix:** add an `NSViewRepresentable` over the plot area whose `NSView`
  overrides `mouseDownCanMoveWindow → false` (and `acceptsFirstMouse`), so AppKit
  yields the drag there; drop `minimumDistance` to ~2. HistoryView.swift:437 overlay.

### 0.2 Purge git badge never appears — M
- **Root cause:** the purge row model `MoTUIItem.location` is a human label
  (e.g. `"Desktop"`, MoInteractive.swift:27), not a path. `MoItemRow.checkGit`
  (InstallerView.swift:442) guards `loc.hasPrefix("/")||"~"` → always false for
  purge → returns before calling git. The badge logic is fed the wrong field.
- **Fix:** surface the artifact's real absolute path on the item (extend the
  `mo purge` parse + `MoTUIItem` with a `path`), feed that to
  `GitSweep.repoRoot()`. Verify against a dirty repo under the purged folder.

### 0.3 Notification threshold can't be set — M
- **Root cause:** only `Store.thresholdAlertsEnabled` (Bool) exists; the actual
  limits are hardcoded in `ThresholdAlerts.evaluate`. No value UI at all.
- **Fix:** add `Store.cpuThresholdPct`, `memThresholdPct`, `sustainMinutes`;
  Settings steppers/sliders under the toggle; wire `evaluate` to read them.

---

## P1 — Reworks (existing features that miss the mark)

### 1.1 Tune-Up → CleanMyMac "Smart Care" model — L
Current Tune-Up is a persistent review dashboard. Henry wants the CleanMyMac
*Smart Care* feel:
- One big centered **Scan** hero (animated) as the entry, not a wall of cards.
- Unified results across modules: **Cleanup** (junk), **Maintenance** (speed),
  **Updates**, **Security** (vulns — see 3.3), **Large & Old**.
- A single **Run** with per-item checkboxes + a visible plan; progress; done summary.
- Keep the persisted snapshot + last-run (already built) under the new shell.
- Reuse existing engines (Clean/Optimize/Updates/Analyze) — no new process paths.

### 1.2 Dev Hygiene + Report — "literally no use" → fold/cut — M
Both read as filler. Recommendation:
- **Dev Hygiene:** fold into Tune-Up/Clean — dev caches are just cleanable junk
  grouped by tool. If kept standalone, it must do more than list+clear: stale
  `node_modules` across all projects, Docker bloat, Xcode DerivedData/simulators,
  with bulk safe-clean. **Recommend: merge, drop the standalone pane.**
- **Report:** a static weekly digest nobody opens. Either make it actionable
  (what-changed deltas, trend lines, export) **or cut it from nav.**
  **Recommend: cut unless we commit to actionable.** ← Henry's call.

---

## P2 — Net-new, high value

### 2.1 Ports suite (rustnet / bandwhich / portpilot / whatportis) — L
Burrow already enumerates **listening** ports natively (PortEnumerator,
proc_pidinfo, no lsof). Add:
- **Outbound/established connections** + remote host + **GeoIP country**
  (socket_fdinfo already carries the foreign address) — *rustnet* (Apache-2.0, safe to draw from).
- **Bandwidth per process** — *bandwhich* (MIT).
- **Filters:** `process:`, `port:`, `state:` (listen/established).
- **Port-conflict detection** (two procs fighting for a port) — *portpilot* (MIT).
- **Inline "what is this port"** lookup — bundle the IANA list offline
  (*whatportis*-style; reference lookup, not a live tool).
- Kill-from-table (have) + copy lsof/kill command.
- ⚠️ GeoIP DB license (see guardrails). avoid killport-tui (no license).

### 2.2 Connectivity / "Get Online" (Hotspot Guide) — L
Captive-portal + device-side rescue, in Burrow's idiom:
- Device-side checklist: iCloud Private Relay / VPN / proxy / custom DNS, each
  with an "Open Settings" deep-link (Burrow already does deep-links).
- Captive-portal probe (`captive.apple.com/hotspot-detect.html`) + **Force Login Page**.
- Diagnose tab: Wi-Fi, IP, reachability, MDM (fuzzy), login-page reachable.
- Deferred/permission-heavy: Wi-Fi scan (CoreWLAN + Location), speed test
  (only multi-stream — single-stream undercounts badly, per the Hotspot Guide
  Reddit thread), DNS/WebRTC-leak checks.

### 2.3 Vulnerability scanning (brew-browser) — M/L
`brew vulns` → OSV.dev CVEs on installed formulae. Opt-in, off by default.
One-click installer for `brew vulns` itself. Dashboard "Exposure" card,
per-package Security rows, "Upgrade to fix" wired to existing upgrade. Casks
unsupported (state honestly). Fits "monitoring & trust." Feeds Tune-Up §1.1.

### 2.4 Notifications expansion — M
- Configurable thresholds (0.3 above) — prerequisite.
- New types: **disk fills in ~N days** (we have the forecaster), **backup
  overdue**, **SMART failing**, **app update available**, **new login item**
  (watcher exists), **large cache/dir growth**, **port newly listening**.
- All opt-in per-type in Settings ▸ Notifications.

### 2.5 Pre-scan-on-open — expanded draft — S/M
Pre-warm on **window open** (user opened Burrow = about to interact), tiered:
- **Prewarm (cheap, local, safe):** Doctor checks (FDA/disk/memory), disk
  free + forecast, listening-ports list (proc_pidinfo, fast), startup inventory
  (have), uninstall list (have), git repo sweep *if cached*.
- **Never prewarm:** anything network (app-update checks, `brew outdated`, vuln
  scan, GeoIP) — privacy; and heavy (full `mo analyze ~`).
- Mechanism: a shared `LocalScanCache` warmed on first window-visible, read by
  Software/Tune-Up/Ports/Doctor so no pane re-scans from cold.

---

## P3 — Net-new, lower / niche

- **Brewfile snapshots** (brew-browser) — `brew bundle` save/restore; new-Mac migration. M
- **brew services** control (brew-browser) — start/stop/restart launchd services. M
- **App security insights** (Updatest) — per-app codesign/notarization/permissions
  via `SecStaticCode`. M. Fits trust.
- **GitHub Releases** as an update source (Updatest) — extends existing Updates detection. S
- **Homebrew trending** (brew-browser) — formulae.brew.sh analytics. L, network, lower value.
- **Homebrew `--adopt`** (Updatest) — bring unmanaged apps under brew. S, niche.

## Skip
- Updatest **Network** (crowd-shared versions) — against local-first posture.
- Cloning any reference app's exact UI/copy.

---

## Already in Burrow (do NOT rebuild)
Update detection (Sparkle · App Store · Electron · Homebrew, UpdateSources.swift),
apps/uninstall, Installer (≈Discover), Analyze, Clean, Optimize, listening Ports,
Doctor, Activity streaming, 18 `burrow_*` MCP tools, metrics history/snapshots.

---

## Proposed execution order
1. **P0 bugs** (chart drag → threshold config → purge badge path).
2. **P1.1 Tune-Up Smart Care** + **P1.2 dev-hygiene/report fold** (needs Henry's cut/keep call).
3. **P2** in value order: ports suite, connectivity, vuln scan, notifications+prescan.
4. **P3** as capacity allows.

Issues: file grouped by track (P0 individually; P1/P2/P3 one epic each) — **after Henry reviews this plan.**
