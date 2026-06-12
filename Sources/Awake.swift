//
//  Awake.swift
//  Burrow
//
//  "Keep Screen On": one IOPMAssertion pair (NoDisplaySleep +
//  PreventUserIdleSystemSleep) with an optional expiry timer. Never asks
//  for admin; releasing the assertions (or app exit) restores normal
//  sleep. State is observable so the menu checkmark, the popover's
//  utility strip, and Settings all read the same source.
//

import Foundation
import IOKit.pwr_mgt
import Combine

final class Awake: ObservableObject {
    static let shared = Awake()

    enum Duration: CaseIterable, Identifiable {
        case minutes15, minutes30, hour1, hours2, untilOff

        var id: Int { seconds.map(Int.init) ?? -1 }

        /// nil = no expiry (until turned off).
        var seconds: TimeInterval? {
            switch self {
            case .minutes15: return 15 * 60
            case .minutes30: return 30 * 60
            case .hour1:     return 60 * 60
            case .hours2:    return 2 * 60 * 60
            case .untilOff:  return nil
            }
        }

        var label: String {
            switch self {
            case .minutes15: return NSLocalizedString("15 minutes", comment: "")
            case .minutes30: return NSLocalizedString("30 minutes", comment: "")
            case .hour1:     return NSLocalizedString("1 hour", comment: "")
            case .hours2:    return NSLocalizedString("2 hours", comment: "")
            case .untilOff:  return NSLocalizedString("Until turned off", comment: "")
            }
        }
    }

    @Published private(set) var isActive = false
    @Published private(set) var expiresAt: Date?

    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0
    private var expiryTimer: Timer?

    private init() {}

    func start(_ duration: Duration) {
        stop()
        let reason = "Burrow Keep Screen On" as CFString
        var ok = IOPMAssertionCreateWithName(kIOPMAssertionTypeNoDisplaySleep as CFString,
                                             IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                             reason, &displayAssertion) == kIOReturnSuccess
        ok = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                         IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                         reason, &systemAssertion) == kIOReturnSuccess && ok
        isActive = ok
        if let secs = duration.seconds {
            expiresAt = Date().addingTimeInterval(secs)
            let timer = Timer(timeInterval: secs, repeats: false) { [weak self] _ in self?.stop() }
            RunLoop.main.add(timer, forMode: .common)
            expiryTimer = timer
        } else {
            expiresAt = nil
        }
    }

    func stop() {
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
        if systemAssertion != 0 { IOPMAssertionRelease(systemAssertion); systemAssertion = 0 }
        expiryTimer?.invalidate()
        expiryTimer = nil
        isActive = false
        expiresAt = nil
    }
}
