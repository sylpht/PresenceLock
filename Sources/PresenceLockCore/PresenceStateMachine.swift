import Foundation

/// Deterministic safety core. It has no camera, UI, timers, or lock implementation.
public final class PresenceStateMachine {
    public private(set) var state: PresenceState = .launchGuard
    public private(set) var hasConfirmedPresence = false
    public private(set) var mode: MonitoringMode
    public let configuration: DetectionConfiguration

    private let requirePostWarningFrame: Bool
    private var absentSinceMonotonic: TimeInterval?
    private var warningStartedAtMonotonic: TimeInterval?
    private var armedForCurrentEpisode = true

    public init(
        mode: MonitoringMode = .learning,
        configuration: DetectionConfiguration = .learningDefault,
        requirePostWarningFrame: Bool = true
    ) {
        self.mode = mode
        self.configuration = configuration
        self.requirePostWarningFrame = requirePostWarningFrame
    }

    /// Use after sleep, logout, camera replacement, or permission loss.
    @discardableResult
    public func resetSession() -> [StateMachineAction] {
        var actions: [StateMachineAction] = []
        if state == .warning {
            actions.append(.warningCancelled)
        }
        absentSinceMonotonic = nil
        warningStartedAtMonotonic = nil
        armedForCurrentEpisode = true
        hasConfirmedPresence = false
        actions.append(contentsOf: transition(to: .launchGuard))
        return actions
    }

    /// Changing mode is a safety boundary. In particular, switching to `armed` while an
    /// absence or warning is already in progress must never inherit that partial decision.
    @discardableResult
    public func setMode(_ newMode: MonitoringMode) -> [StateMachineAction] {
        guard newMode != mode else { return [] }
        mode = newMode
        return resetSession()
    }

    /// The UI and final camera check share this monotonic deadline.
    public var warningDeadlineMonotonic: TimeInterval? {
        guard state == .warning, let warningStartedAtMonotonic else { return nil }
        return warningStartedAtMonotonic + configuration.warningSeconds
    }

    /// Remaining warning time for presentation by the app.
    public func warningRemainingSeconds(atMonotonic monotonicNow: TimeInterval) -> TimeInterval? {
        guard let warningDeadlineMonotonic, monotonicNow.isFinite else { return nil }
        return min(configuration.warningSeconds, max(0, warningDeadlineMonotonic - monotonicNow))
    }

    /// Explicit acknowledgement from the warning UI. The click is also normal input, but
    /// handling it synchronously prevents a lock decision from racing the next polling tick.
    @discardableResult
    public func acknowledgePresence() -> [StateMachineAction] {
        var actions: [StateMachineAction] = []
        let wasWarning = state == .warning
        hasConfirmedPresence = true
        absentSinceMonotonic = nil
        warningStartedAtMonotonic = nil
        armedForCurrentEpisode = true
        if wasWarning { actions.append(.warningCancelled) }
        actions.append(contentsOf: transition(to: .active))
        return actions
    }

    public func update(_ input: StateMachineInput) -> [StateMachineAction] {
        var actions: [StateMachineAction] = []

        guard input.sessionActive, input.monotonicNow.isFinite,
              input.idleSeconds.isFinite, input.idleSeconds >= 0,
              input.updateGapSeconds.isFinite, input.updateGapSeconds >= 0,
              input.updateGapSeconds <= configuration.maximumUpdateGapSeconds else {
            return resetSession()
        }

        // Fresh input is proof of presence, but its content is never inspected.
        if input.inputOccurred || input.idleSeconds < 1 {
            return acknowledgePresence()
        }

        if input.idleSeconds < configuration.probeIdleSeconds {
            let wasWarning = state == .warning
            absentSinceMonotonic = nil
            warningStartedAtMonotonic = nil
            if wasWarning { actions.append(.warningCancelled) }
            actions.append(contentsOf: transition(to: hasConfirmedPresence ? .quiet : .launchGuard))
            return actions
        }

        let sampleAge = input.monotonicNow - input.reading.capturedAtMonotonic
        let readingIsFresh = sampleAge >= 0 && sampleAge <= configuration.maximumSampleAgeSeconds

        // A newer empty frame must not erase presence seen between two decision ticks.
        if input.cameraEvidence.sawPresence {
            hasConfirmedPresence = true
            armedForCurrentEpisode = true
        }

        guard input.reading.cameraAvailable,
              readingIsFresh,
              !input.cameraEvidence.sawUncertainty,
              input.reading.observation != .unknown else {
            let wasWarning = state == .warning
            absentSinceMonotonic = nil
            warningStartedAtMonotonic = nil
            if wasWarning { actions.append(.warningCancelled) }
            actions.append(contentsOf: transition(to: .unknown))
            return actions
        }

        let observation = input.cameraEvidence.sawPresence ? .present : input.reading.observation
        switch observation {
        case .present:
            let wasWarning = state == .warning
            hasConfirmedPresence = true
            absentSinceMonotonic = nil
            warningStartedAtMonotonic = nil
            armedForCurrentEpisode = true
            if wasWarning { actions.append(.warningCancelled) }
            actions.append(contentsOf: transition(to: .presentQuiet))

        case .absent:
            // Never act on absence observed before this process has seen the user.
            guard hasConfirmedPresence else {
                absentSinceMonotonic = nil
                warningStartedAtMonotonic = nil
                actions.append(contentsOf: transition(to: .launchGuard))
                return actions
            }

            // Uncertainty can clear the timers after a decision, but it cannot
            // establish that someone returned. Wait for presence before warning again.
            guard armedForCurrentEpisode else {
                actions.append(contentsOf: transition(to: .triggered))
                return actions
            }

            if absentSinceMonotonic == nil {
                absentSinceMonotonic = input.monotonicNow
                warningStartedAtMonotonic = nil
            }

            let absentDuration = input.monotonicNow - (absentSinceMonotonic ?? input.monotonicNow)
            guard absentDuration >= configuration.absenceConfirmationSeconds else {
                actions.append(contentsOf: transition(to: .suspectedAway))
                return actions
            }

            let warningStart: TimeInterval
            if let warningStartedAtMonotonic {
                warningStart = warningStartedAtMonotonic
            } else {
                warningStart = input.monotonicNow
                warningStartedAtMonotonic = warningStart
                actions.append(.warningStarted)
            }

            let deadline = warningStart + configuration.warningSeconds
            guard input.monotonicNow >= deadline else {
                actions.append(contentsOf: transition(to: .warning))
                return actions
            }

            // A fresh reading from before the countdown ended cannot confirm the lock.
            // Legacy log replay has only the older, less strict rule to reproduce.
            if requirePostWarningFrame, input.reading.capturedAtMonotonic < deadline {
                actions.append(contentsOf: transition(to: .warning))
                return actions
            }

            armedForCurrentEpisode = false
            absentSinceMonotonic = nil
            warningStartedAtMonotonic = nil
            actions.append(mode.performsRealLock ? .lock : .wouldLock)
            actions.append(contentsOf: transition(to: .triggered))

        case .unknown:
            break // Handled by the guard above.
        }

        return actions
    }

    private func transition(to newState: PresenceState) -> [StateMachineAction] {
        guard newState != state else { return [] }
        let previous = state
        state = newState
        return [.stateChanged(from: previous, to: newState)]
    }
}
