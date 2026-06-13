# Burrow 0.7.0

The big one: a top-to-bottom redesign of every tool — onboarding, a real Clean
review pipeline, a new Software tab, and rebuilt Status, popover, Analyze, and
Settings — plus a wave of polish on top.

## A redesigned app
- **First-run onboarding.** A short, skippable intro: grant Full Disk Access
  (with a one-click relaunch), confirm the `mo` engine is installed and see its
  version, and a "free & open source" card. No more cold start.
- **Clean, reviewable before it runs.** Scan now streams a live count-up — the
  animation *is* the scan — into a per-item **review screen**: tri-state category
  cards, honest "what this frees" lines, open-app badges, and a "Permanently
  clean · N GB" pill. Deselected items ride a fenced whitelist session for
  exactly one run and are restored byte-for-byte after. New **Move-to-Trash
  mode** recycles only the reviewed items (recoverable) instead of permanent
  deletion.
- **New Software tab.** **Uninstall** with an expandable per-app leftover review
  (auto-selects app/support/prefs/containers; flags caches/logs for review) and
  two-path removal. **Updates** — one list with Sparkle / App Store / Electron /
  Homebrew badges (network only on click). **Startup** — a read-only Launch
  Agents/Daemons inventory with problem rows.
- **Rebuilt Status dashboard.** Corner chips, battery ring gauges (Bluetooth
  folded in), a low-space gradient bar, a read-only fan tile, a power column
  (honest "—" where the kernel won't say), and an independently scrolling process
  table with a per-row Quit/Force-Kill menu.
- **Rebuilt menu-bar popover.** A one-line health header + hardware chips, six
  metric tiles, a battery card with "⚡ Top drain", a Stay-Awake / Wipe / Eject
  strip, and a Clean Watch footer.
- **Analyze: real scan progress.** A true per-child counter ("● ~/Downloads ·
  3/12") — Burrow drives the loop, so the number is real, never invented.
- **Settings, reorganized.** Tabbed panel — General / Maintenance / Menu Bar /
  Advanced — with a whitelist manager (Protected Items), Permanent|Trash removal
  mode, status-item Icon|Metrics mode, and global shortcut recorders.
- **Menu-bar tools.** Keep Screen On (with durations), Clean Screen (Esc always
  exits), an About panel, and manual Check for Updates.

## Charts & metrics
- **History charts as bars** — CPU usage, GPU usage, and health score render as
  clean, evenly-spaced bars at every range.
- **Real GPU usage** on Apple Silicon, read natively and persisted (no more flat
  zero).
- **Tighter live tiles** — network sparkline windowed to the last couple of
  minutes, GPU as bars like CPU, and a new fan RPM-over-time sparkline.

## Notifications
- **Finish-line notices** when a real clean, optimize, or uninstall completes —
  with what it freed.
- **Opt-in smart reminders** — low disk, full Trash, or "it's been a while since
  your last clean." Off by default and throttled so they never get chatty.

## Polish & hardening
- One-click **Relaunch** when Full Disk Access is granted mid-session.
- Truthful Touch ID copy (it covers terminal `sudo`, not Burrow's own admin
  prompts).
- Clean-review safety: whitelist session paths glob-escaped, unreadable
  whitelist aborts instead of overwriting, session always restored when a run
  ends.
- Popover height tracks content; Wipe shows an armed state; deduped the doubled
  "macOS" version label.
- ~230 new strings localized in 简体中文 and 繁體中文; accessibility labels and
  Reduce Motion on every new surface.

## For agents & under the hood
- **Steadier metrics.** A single malformed sample no longer blanks the
  dashboard — bad rows are skipped, counted, and the latest good reading is
  used. `GET /info` and the `burrow_info` MCP tool now report decode-skip counts,
  so you can tell at a glance whether data is flowing.
- **One gated policy for actions.** The app and the MCP server now decide "can
  this run?" through a single shared gate, and the agent-facing action tools
  return a structured result summary (space freed, items, categories) alongside
  the raw output, on a frozen, golden-tested JSON contract.
- **Lighter History.** The History view's auto-refresh is demand-driven now — it
  stops the moment you leave the view instead of leaving a timer running.
- **Deeper, more testable core.** The `mo` runner (honest timeouts,
  runner-classified auth-cancel), the metrics reader, and the actions core were
  consolidated into deep modules with a large new test suite.
