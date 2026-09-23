import Foundation
import IOKit.pwr_mgt

/// Keeps the Mac awake using a power-management assertion (the same mechanism as `caffeinate`).
/// The system drops the assertion automatically if the app quits or crashes.
@MainActor
final class SleepPreventer: ObservableObject {
    @Published private(set) var isActive = false
    /// When the current session ends; nil means indefinitely.
    @Published private(set) var endDate: Date?
    @Published private(set) var keepsDisplayAwake = false

    private var assertionID = IOPMAssertionID(0)
    private var hasAssertion = false
    private var timer: Timer?

    /// Starts (or restarts) keep-awake. `duration` nil means until turned off.
    func activate(for duration: TimeInterval?, keepDisplayAwake: Bool) {
        releaseAssertion()
        let type = keepDisplayAwake
            ? kIOPMAssertionTypePreventUserIdleDisplaySleep
            : kIOPMAssertionTypePreventUserIdleSystemSleep
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "ControlBar keep-awake" as CFString, &id)
        guard result == kIOReturnSuccess else {
            NSLog("ControlBar: failed to create power assertion (\(result))")
            deactivate()
            return
        }
        assertionID = id
        hasAssertion = true
        isActive = true
        keepsDisplayAwake = keepDisplayAwake

        if let duration, duration > 0 {
            let end = Date().addingTimeInterval(duration)
            endDate = end
            let timer = Timer(fire: end, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.deactivate() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            endDate = nil
        }
    }

    /// Switches display mode without resetting the remaining time.
    func setKeepDisplayAwake(_ keepDisplayAwake: Bool) {
        guard isActive, keepDisplayAwake != keepsDisplayAwake else { return }
        activate(for: endDate.map { max(1, $0.timeIntervalSinceNow) }, keepDisplayAwake: keepDisplayAwake)
    }

    func deactivate() {
        releaseAssertion()
        isActive = false
        endDate = nil
    }

    /// Human-readable remaining time, e.g. "1 h 20 min left".
    var statusDescription: String {
        guard isActive else { return "Off" }
        guard let endDate else { return "On — indefinitely" }
        return "On — \(Self.format(max(0, endDate.timeIntervalSinceNow))) left"
    }

    static func format(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    private func releaseAssertion() {
        timer?.invalidate()
        timer = nil
        if hasAssertion {
            IOPMAssertionRelease(assertionID)
            hasAssertion = false
        }
    }
}

/// Preset durations offered in menus and settings. 0 means indefinitely.
enum KeepAwakeDuration {
    static let presets: [(title: String, seconds: TimeInterval)] = [
        ("Indefinitely", 0),
        ("15 minutes", 15 * 60),
        ("30 minutes", 30 * 60),
        ("1 hour", 3600),
        ("2 hours", 2 * 3600),
        ("4 hours", 4 * 3600),
        ("8 hours", 8 * 3600),
    ]
}
