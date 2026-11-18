import Foundation
import PresenceLockCore

/// Persists timing thresholds and whether passive monitoring should resume. The operating mode
/// deliberately remains session-only so a relaunch can never arm real locking without an
/// explicit user action.
final class PresenceLockPreferences {
    private enum Key {
        static let probeIdleSeconds = "timing.probeIdleSeconds"
        static let absenceConfirmationSeconds = "timing.absenceConfirmationSeconds"
        static let warningSeconds = "timing.warningSeconds"
        static let monitoringEnabled = "monitoring.enabled"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadConfiguration() -> DetectionConfiguration {
        let fallback = DetectionConfiguration.learningDefault
        return makeConfiguration(
            probeIdleSeconds: storedDouble(forKey: Key.probeIdleSeconds)
                ?? fallback.probeIdleSeconds,
            absenceConfirmationSeconds: storedDouble(forKey: Key.absenceConfirmationSeconds)
                ?? fallback.absenceConfirmationSeconds,
            warningSeconds: storedDouble(forKey: Key.warningSeconds)
                ?? fallback.warningSeconds
        )
    }

    func save(_ configuration: DetectionConfiguration) {
        defaults.set(configuration.probeIdleSeconds, forKey: Key.probeIdleSeconds)
        defaults.set(
            configuration.absenceConfirmationSeconds,
            forKey: Key.absenceConfirmationSeconds
        )
        defaults.set(configuration.warningSeconds, forKey: Key.warningSeconds)
    }

    func loadMonitoringEnabled() -> Bool {
        defaults.bool(forKey: Key.monitoringEnabled)
    }

    func saveMonitoringEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Key.monitoringEnabled)
    }

    func makeConfiguration(
        probeIdleSeconds: TimeInterval,
        absenceConfirmationSeconds: TimeInterval,
        warningSeconds: TimeInterval
    ) -> DetectionConfiguration {
        DetectionConfiguration(
            probeIdleSeconds: Self.clamp(probeIdleSeconds, to: 5...300, fallback: 8),
            absenceConfirmationSeconds: Self.clamp(
                absenceConfirmationSeconds,
                to: 5...300,
                fallback: 20
            ),
            warningSeconds: Self.clamp(warningSeconds, to: 3...60, fallback: 5),
            maximumSampleAgeSeconds: 3,
            maximumUpdateGapSeconds: 5,
            sampleIntervalSeconds: 2
        )
    }

    private func storedDouble(forKey key: String) -> Double? {
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.double(forKey: key)
        return value.isFinite ? value : nil
    }

    private static func clamp(
        _ value: TimeInterval,
        to range: ClosedRange<TimeInterval>,
        fallback: TimeInterval
    ) -> TimeInterval {
        guard value.isFinite else { return fallback }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
