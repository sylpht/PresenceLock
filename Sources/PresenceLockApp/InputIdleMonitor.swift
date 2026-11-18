import CoreGraphics
import Darwin
import Foundation

struct InputIdleMonitor {
    func secondsSinceLastInput() -> TimeInterval? {
        guard let anyInputEvent = CGEventType(rawValue: UInt32.max) else { return nil }
        let seconds = CGEventSource.secondsSinceLastEventType(
            .combinedSessionState,
            eventType: anyInputEvent
        )
        let elapsedSinceBoot = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000
        return Self.validDuration(seconds, elapsedSinceBoot: elapsedSinceBoot)
    }

    static func validDuration(_ seconds: TimeInterval, elapsedSinceBoot: TimeInterval) -> TimeInterval? {
        // Includes sleep. A counter larger than the lifetime of this boot cannot be HID idle time.
        guard seconds.isFinite, seconds >= 0, seconds <= elapsedSinceBoot + 1 else { return nil }
        return seconds
    }

    static func inputResumed(previousIdle: TimeInterval, currentIdle: TimeInterval, elapsed: TimeInterval) -> Bool {
        // An intervening event can leave the same idle value on two consecutive polls.
        previousIdle >= 1 && (currentIdle < 1 || currentIdle + 0.25 < previousIdle + elapsed)
    }
}
