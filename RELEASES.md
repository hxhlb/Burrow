# Burrow 0.7.0

A polish-and-fixes release on top of the 2026-06 redesign: clearer history
charts, accurate GPU readings, notifications when long jobs finish, and a
friendlier first run.

## Charts & metrics
- **History charts as bars.** CPU usage, GPU usage, and health score now render
  as clean, evenly-spaced bars across every time range — easier to read at a
  glance than a line.
- **Real GPU usage.** On Apple Silicon, GPU utilization is read natively and
  persisted, so the tiles and history show the true figure instead of a flat
  zero.
- **Tighter live tiles.** The network sparkline windows to the last couple of
  minutes so current bursts actually show, the GPU tile reads as bars like CPU,
  and the fan tile gains an RPM-over-time sparkline.
- **Compact, scrollable process table** on Status — more processes, less wasted
  height.

## Notifications
- **Finish-line notices.** Get notified when a real clean, optimize, or
  uninstall finishes — with what it freed.
- **Opt-in smart reminders.** Optional nudges when disk space runs low, the
  Trash is holding gigabytes, or it's been a while since your last clean. Off by
  default and throttled so they never get chatty; toggle both in Settings.

## Onboarding & Settings
- **Engine check on first run.** Onboarding confirms the `mo` engine is
  installed and shows its version before you start.
- **Settings, redrawn.** A first-class Settings pane — no boxed-dialog chrome —
  with truthful Touch ID copy (it covers terminal `sudo`, not Burrow's own
  administrator prompts).
- **One-click relaunch for Full Disk Access.** Grant FDA and Burrow offers to
  relaunch right there, since macOS only applies it to a fresh launch.

## Fixes & hardening
- Clean review protects deselected items more safely: whitelist session paths
  are glob-escaped (a path with brackets or spaces still matches itself), an
  unreadable whitelist aborts instead of being overwritten, and the fenced
  session is always restored when a run ends — even if you navigate away.
- Popover height tracks its content; the Wipe action shows an armed state.
- Deduped the doubled "macOS" in the version label.
