//
//  Notifications.swift
//  Burrow
//
//  User notifications, two kinds:
//
//    * Completion notices — a long operation (real clean, optimize,
//      uninstall) finished while Burrow wasn't frontmost. Posted by
//      OperationCenter.end for ops that opted in, carrying the parsed
//      result (freed bytes etc.) as the body. ON by default; Settings ▸
//      General ▸ Notifications turns them off.
//
//    * Smart reminders — opt-in, throttled nudges modeled on the canon
//      polished cleaner apps ship (a "Trash exceeds N GB" notice, a
//      low-disk-space alert, periodic cleanup reminders): your last
//      clean was weeks ago, free space crossed under 10%, the Trash is
//      holding gigabytes. OFF by default, at most one notice per rule
//      per week (reviewers pan chatty cleaners — throttling is the
//      feature), and never while the app is frontmost.
//
//  UNUserNotificationCenter authorization is requested lazily by the
//  first actual post — launching Burrow never prompts. The whole class
//  is inert under XCTest (TEST_HOST shell).
//

import AppKit
import UserNotifications

// MARK: - Pure reminder rules (unit-tested)

enum ReminderRules {
    /// Free-space fraction that trips the low-disk notice…
    static let diskLowFraction = 0.10
    /// …and the higher fraction that re-arms it (hysteresis: a disk
    /// hovering at the threshold must not flap).
    static let diskRecoverFraction = 0.12
    /// Trash size that trips the full-Trash notice.
    static let trashThresholdBytes: Int64 = 5 << 30   // 5 GiB
    /// Days without a completed clean before the cadence nudge speaks.
    static let cleanLapseDays = 14
    /// Hard per-rule cooldown: nothing repeats more than weekly.
    static let repeatCooldownDays = 7

    struct Decision: Equatable {
        let notify: Bool
        /// Persisted back as the rule's hysteresis flag.
        let nowActive: Bool
    }

    /// Low disk: one notice when free space crosses under the line,
    /// re-armed only after it recovers past `diskRecoverFraction`.
    static func diskLow(freeFraction: Double, active: Bool) -> Decision {
        if freeFraction < diskLowFraction {
            return Decision(notify: !active, nowActive: true)
        }
        if freeFraction >= diskRecoverFraction {
            return Decision(notify: false, nowActive: false)
        }
        return Decision(notify: false, nowActive: active)   // hysteresis band
    }

    /// Full Trash: one notice when the size crosses the threshold,
    /// re-armed once it shrinks below half (i.e. was emptied), with the
    /// weekly cooldown on top.
    static func trashFull(bytes: Int64, active: Bool, lastNotice: Date?, now: Date = Date()) -> Decision {
        if bytes >= trashThresholdBytes {
            guard !active else { return Decision(notify: false, nowActive: true) }
            let cooled = lastNotice.map { now.timeIntervalSince($0) >= Double(repeatCooldownDays) * 86_400 } ?? true
            return Decision(notify: cooled, nowActive: cooled)
        }
        if bytes < trashThresholdBytes / 2 {
            return Decision(notify: false, nowActive: false)
        }
        return Decision(notify: false, nowActive: active)
    }

    /// Days since the last completed clean when a cadence reminder is
    /// due, nil otherwise. Only speaks when a previous clean EXISTS —
    /// "you haven't cleaned in N weeks" must never be invented for a
    /// Mac that simply never cleaned.
    static func cleanLapsedDays(lastClean: Date?, lastNotice: Date?, now: Date = Date()) -> Int? {
        guard let lastClean else { return nil }
        let days = Int(now.timeIntervalSince(lastClean) / 86_400)
        guard days >= cleanLapseDays else { return nil }
        if let lastNotice, now.timeIntervalSince(lastNotice) < Double(repeatCooldownDays) * 86_400 {
            return nil
        }
        return days
    }

    /// Most recent completed `clean` session from `mo history`.
    /// `started_at` is "yyyy-MM-dd HH:mm:ss" in local time; rows that
    /// don't parse contribute nothing (we never guess).
    static func lastCompletedClean(_ sessions: [HistorySession]) -> Date? {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sessions
            .filter { $0.command == "clean" && $0.isComplete }
            .compactMap { fmt.date(from: $0.startedAt) }
            .max()
    }
}

// MARK: - The notifier

@MainActor
final class BurrowNotifier: NSObject {
    static let shared = BurrowNotifier()

    /// Inert under XCTest: the TEST_HOST shell must never prompt for
    /// notification permission or litter Notification Center.
    private let inert = Foundation.ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil

    private var reminderTimer: Timer?
    /// `mo history` is spawned at most daily for the cadence rule.
    private var lastHistoryProbeAt: Date?

    private override init() { super.init() }

    // MARK: Completion notices

    /// Called by OperationCenter.end for ops that opted in. Posts whenever
    /// the Settings toggle is on — including while Burrow is frontmost: a
    /// real clean can take minutes, the user often tabs away, and the
    /// `willPresent` handler below lets the banner show even in-app. (The
    /// background reminders still stay silent while active — those are
    /// nudges, not results.)
    func operationCompleted(label: String, success: Bool, detail: String) {
        guard !inert, Store.notifyOnCompletion else { return }
        let content = UNMutableNotificationContent()
        content.title = String(format: success ? NSLocalizedString("%@ — done", comment: "notification title")
                                               : NSLocalizedString("%@ — failed", comment: "notification title"),
                               label)
        content.body = detail.isEmpty
            ? (success ? NSLocalizedString("Finished.", comment: "")
                       : NSLocalizedString("Open Burrow for details.", comment: ""))
            : detail
        post(content, id: "burrow-op-\(UUID().uuidString)")
    }

    // MARK: Smart reminders

    /// Started once from AppDelegate.startServices. Hourly sweep — each
    /// rule throttles itself — plus a first pass a couple of minutes
    /// after launch so a Mac that's already low on disk hears about it
    /// today, not in an hour.
    func startReminders() {
        guard !inert, reminderTimer == nil else { return }
        let timer = Timer(timeInterval: 3_600, repeats: true) { _ in
            Task { @MainActor in BurrowNotifier.shared.checkReminders() }
        }
        RunLoop.main.add(timer, forMode: .common)
        reminderTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
            self?.checkReminders()
        }
    }

    func checkReminders() {
        guard !inert, Store.smartRemindersEnabled else { return }
        // Reminders are background nudges by definition — while the user
        // is in the app the UI already says all of this.
        guard NSApp?.isActive != true else { return }
        let probeHistory = lastHistoryProbeAt.map { Date().timeIntervalSince($0) > 86_400 } ?? true
        if probeHistory { lastHistoryProbeAt = Date() }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let free = Self.freeDiskSpace()
            let trashBytes = Self.trashSizeBytes()
            let lastClean = probeHistory ? ReminderRules.lastCompletedClean(MoleHistory.load()) : nil
            Task { @MainActor in
                self?.evaluateReminders(free: free, trashBytes: trashBytes, lastClean: lastClean)
            }
        }
    }

    private func evaluateReminders(free: (fraction: Double, freeBytes: Int64)?,
                                   trashBytes: Int64, lastClean: Date?) {
        guard Store.smartRemindersEnabled else { return }

        if let free {
            let d = ReminderRules.diskLow(freeFraction: free.fraction, active: Store.diskLowNoticeActive)
            Store.diskLowNoticeActive = d.nowActive
            if d.notify {
                postReminder(
                    title: NSLocalizedString("Disk space is running low", comment: ""),
                    body: String(format: NSLocalizedString("Only %@ free (%.0f%%). A clean can usually win some of it back.", comment: ""),
                                 Fmt.bytes(free.freeBytes), free.fraction * 100),
                    pane: "clean", id: "burrow-reminder-disk")
            }
        }

        let t = ReminderRules.trashFull(bytes: trashBytes, active: Store.trashNoticeActive,
                                        lastNotice: Store.lastTrashReminderAt)
        Store.trashNoticeActive = t.nowActive
        if t.notify {
            Store.lastTrashReminderAt = Date()
            postReminder(
                title: String(format: NSLocalizedString("Your Trash is holding %@", comment: ""), Fmt.bytes(trashBytes)),
                body: NSLocalizedString("Deleted files still take up disk space until the Trash is emptied.", comment: ""),
                pane: nil, id: "burrow-reminder-trash")
        }

        if let days = ReminderRules.cleanLapsedDays(lastClean: lastClean,
                                                    lastNotice: Store.lastCleanReminderAt) {
            Store.lastCleanReminderAt = Date()
            postReminder(
                title: String(format: NSLocalizedString("It's been %d days since your last clean", comment: ""), days),
                body: NSLocalizedString("Caches grow back on their own — a quick scan shows what's reclaimable.", comment: ""),
                pane: "clean", id: "burrow-reminder-clean")
        }
    }

    // MARK: Probes (off-main, best-effort)

    /// Free fraction + bytes for the volume holding the user's home.
    private nonisolated static func freeDiskSpace() -> (fraction: Double, freeBytes: Int64)? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        guard let vals = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                            .volumeTotalCapacityKey]),
              let avail = vals.volumeAvailableCapacityForImportantUsage,
              let total = vals.volumeTotalCapacity, total > 0 else { return nil }
        return (Double(avail) / Double(total), avail)
    }

    /// Allocated size of the user's Trash. Without Full Disk Access
    /// macOS hides ~/.Trash → enumeration yields nothing → 0 → no
    /// reminder. We measure or stay silent; never guess.
    private nonisolated static func trashSizeBytes() -> Int64 {
        let fm = FileManager.default
        let trash = (try? fm.url(for: .trashDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: false))
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".Trash")
        guard let enumerator = fm.enumerator(at: trash,
                                             includingPropertiesForKeys: [.totalFileAllocatedSizeKey,
                                                                          .fileAllocatedSizeKey],
                                             options: [], errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let vals = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey,
                                                               .fileAllocatedSizeKey]) else { continue }
            total += Int64(vals.totalFileAllocatedSize ?? vals.fileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: Delivery

    private func postReminder(title: String, body: String, pane: String?, id: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let pane { content.userInfo = ["pane": pane] }
        post(content, id: id)
    }

    /// Deliver, requesting authorization lazily on the very first post.
    /// Denied = stay silent forever; the OS owns that choice.
    private nonisolated func post(_ content: UNMutableNotificationContent, id: String) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.alert]) { granted, _ in
                    if granted { center.add(request) }
                }
            case .denied:
                break
            default:
                center.add(request)
            }
        }
    }
}

// MARK: - Click routing

extension BurrowNotifier: UNUserNotificationCenterDelegate {
    /// Show the banner even when Burrow is frontmost. Without this, macOS
    /// silently drops foreground notifications — which is why completion
    /// notices never appeared while the window was open.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    /// A click brings Burrow forward; reminders that name a tool land on
    /// it (the clean nudges open Clean). Completions don't force a pane —
    /// the finished run's receipt is already on whichever tab ran it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let pane = response.notification.request.content.userInfo["pane"] as? String
        Task { @MainActor in
            if #available(macOS 14, *) {
                if pane == "clean" {
                    AppDelegate.shared?.openMainWindow(initial: .tool(.clean))
                } else {
                    AppDelegate.shared?.bringForward()
                }
            }
            completionHandler()
        }
    }
}
