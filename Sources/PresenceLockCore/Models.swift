import Foundation

public enum MonitoringMode: String, Codable, CaseIterable, Sendable {
    case learning
    case shadow
    case armed

    public var performsRealLock: Bool { self == .armed }
}

public enum PresenceObservation: String, Codable, Sendable {
    case present
    case absent
    case unknown
}

public enum PresenceState: String, Codable, Sendable {
    case launchGuard
    case active
    case quiet
    case presentQuiet
    case suspectedAway
    case warning
    case unknown
    case triggered
}

public struct DetectionConfiguration: Codable, Equatable, Sendable {
    public let probeIdleSeconds: TimeInterval
    public let absenceConfirmationSeconds: TimeInterval
    public let warningSeconds: TimeInterval
    public let maximumSampleAgeSeconds: TimeInterval
    public let maximumUpdateGapSeconds: TimeInterval
    public let sampleIntervalSeconds: TimeInterval

    public init(
        probeIdleSeconds: TimeInterval = 8,
        absenceConfirmationSeconds: TimeInterval = 20,
        warningSeconds: TimeInterval = 5,
        maximumSampleAgeSeconds: TimeInterval = 3,
        maximumUpdateGapSeconds: TimeInterval = 5,
        sampleIntervalSeconds: TimeInterval = 2
    ) {
        self.probeIdleSeconds = Self.validated(probeIdleSeconds, minimum: 1, fallback: 8)
        self.absenceConfirmationSeconds = Self.validated(absenceConfirmationSeconds, minimum: 1, fallback: 20)
        self.warningSeconds = Self.validated(warningSeconds, minimum: 1, fallback: 5)
        self.maximumSampleAgeSeconds = Self.validated(maximumSampleAgeSeconds, minimum: 0.25, fallback: 3)
        self.maximumUpdateGapSeconds = Self.validated(maximumUpdateGapSeconds, minimum: 1, fallback: 5)
        self.sampleIntervalSeconds = Self.validated(sampleIntervalSeconds, minimum: 0.25, fallback: 2)
    }

    public static let learningDefault = DetectionConfiguration()

    private static func validated(
        _ value: TimeInterval,
        minimum: TimeInterval,
        fallback: TimeInterval
    ) -> TimeInterval {
        value.isFinite ? max(minimum, value) : fallback
    }
}

public struct PresenceReading: Codable, Equatable, Sendable {
    public var observation: PresenceObservation
    public var confidence: Double
    public var capturedAt: Date
    public var capturedAtMonotonic: TimeInterval
    public var cameraAvailable: Bool

    public init(
        observation: PresenceObservation,
        confidence: Double,
        capturedAt: Date,
        capturedAtMonotonic: TimeInterval = ProcessInfo.processInfo.systemUptime,
        cameraAvailable: Bool
    ) {
        self.observation = observation
        self.confidence = confidence
        self.capturedAt = capturedAt
        self.capturedAtMonotonic = capturedAtMonotonic
        self.cameraAvailable = cameraAvailable
    }

    public static func unknown(
        at date: Date = Date(),
        monotonic: TimeInterval = ProcessInfo.processInfo.systemUptime,
        cameraAvailable: Bool = false
    ) -> PresenceReading {
        PresenceReading(
            observation: .unknown,
            confidence: 0,
            capturedAt: date,
            capturedAtMonotonic: monotonic,
            cameraAvailable: cameraAvailable
        )
    }
}

/// Results seen since the last decision tick, even if a later frame replaced them.
public struct CameraTickEvidence: Codable, Equatable, Sendable {
    public var sawPresence: Bool
    public var sawUncertainty: Bool

    public init(sawPresence: Bool = false, sawUncertainty: Bool = false) {
        self.sawPresence = sawPresence
        self.sawUncertainty = sawUncertainty
    }

    public static let none = CameraTickEvidence()
}

public struct StateMachineInput: Equatable, Sendable {
    public var now: Date
    public var monotonicNow: TimeInterval
    public var idleSeconds: TimeInterval
    public var inputOccurred: Bool
    public var updateGapSeconds: TimeInterval
    public var reading: PresenceReading
    public var sessionActive: Bool
    public var cameraEvidence: CameraTickEvidence

    public init(
        now: Date,
        monotonicNow: TimeInterval = ProcessInfo.processInfo.systemUptime,
        idleSeconds: TimeInterval,
        inputOccurred: Bool = false,
        updateGapSeconds: TimeInterval = 0,
        reading: PresenceReading,
        sessionActive: Bool = true,
        cameraEvidence: CameraTickEvidence = .none
    ) {
        self.now = now
        self.monotonicNow = monotonicNow
        self.idleSeconds = idleSeconds
        self.inputOccurred = inputOccurred
        self.updateGapSeconds = updateGapSeconds
        self.reading = reading
        self.sessionActive = sessionActive
        self.cameraEvidence = cameraEvidence
    }
}

public enum StateMachineAction: Equatable, Sendable {
    case stateChanged(from: PresenceState, to: PresenceState)
    case warningStarted
    case warningCancelled
    case wouldLock
    case lock
}

/// Exact inputs used for a decision tick. Older journal rows omit this metadata.
public struct DecisionReplayTick: Codable, Equatable, Sendable {
    public let monotonicTime: TimeInterval
    public let updateGapSeconds: TimeInterval
    public let idleSeconds: TimeInterval
    public let inputOccurred: Bool
    public let configuration: DetectionConfiguration?
    public let cameraPreviewActive: Bool?
    public let cameraEvidence: CameraTickEvidence?
    /// Independent experiment on a baseline-empty frame, only available on newer recordings.
    public let poseShadow: PoseShadowSample?

    public init(
        monotonicTime: TimeInterval,
        updateGapSeconds: TimeInterval,
        idleSeconds: TimeInterval,
        inputOccurred: Bool,
        configuration: DetectionConfiguration? = nil,
        cameraPreviewActive: Bool? = nil,
        cameraEvidence: CameraTickEvidence? = nil,
        poseShadow: PoseShadowSample? = nil
    ) {
        self.monotonicTime = monotonicTime
        self.updateGapSeconds = updateGapSeconds
        self.idleSeconds = idleSeconds
        self.inputOccurred = inputOccurred
        self.configuration = configuration
        self.cameraPreviewActive = cameraPreviewActive
        self.cameraEvidence = cameraEvidence
        self.poseShadow = poseShadow
    }
}

public struct ObservationRecord: Codable, Equatable, Sendable {
    public var id: UUID
    /// On an execution result, identifies the decision that requested a system action.
    public var lockDecisionID: UUID?
    public var isLockRequestDiagnostic: Bool {
        replayTick == nil && (event == "lockSuppressed" || event == "lockFailed" || event == "lockRequestAccepted")
    }
    public var timestamp: Date
    public var idleSeconds: TimeInterval
    public var observation: PresenceObservation
    public var confidence: Double
    public var cameraAvailable: Bool
    public var readingAgeSeconds: TimeInterval?
    public var state: PresenceState
    public var mode: MonitoringMode
    public var event: String?
    public var replayTick: DecisionReplayTick?

    public init(
        id: UUID = UUID(),
        timestamp: Date,
        idleSeconds: TimeInterval,
        observation: PresenceObservation,
        confidence: Double,
        cameraAvailable: Bool,
        readingAgeSeconds: TimeInterval? = nil,
        state: PresenceState,
        mode: MonitoringMode,
        event: String? = nil,
        replayTick: DecisionReplayTick? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.idleSeconds = idleSeconds
        self.observation = observation
        self.confidence = confidence
        self.cameraAvailable = cameraAvailable
        self.readingAgeSeconds = readingAgeSeconds
        self.state = state
        self.mode = mode
        self.event = event
        self.replayTick = replayTick
    }
}

public enum PredictionLabel: String, Codable, Sendable {
    case confirmedDeparture
    case falseAlarm
}

public struct PredictionFeedback: Codable, Equatable, Sendable {
    public var predictionID: UUID
    public var timestamp: Date
    public var label: PredictionLabel

    public init(predictionID: UUID, timestamp: Date = Date(), label: PredictionLabel) {
        self.predictionID = predictionID
        self.timestamp = timestamp
        self.label = label
    }
}

public enum IdleEpisodeLabel: String, Codable, Sendable {
    case departed
    case stayedPresent
}

/// A label for a complete no-input episode, recorded when input resumes. Unlike prediction
/// feedback, this can describe an episode where the baseline configuration never fired.
public struct IdleEpisodeFeedback: Codable, Equatable, Sendable {
    public var episodeID: UUID
    public var timestamp: Date
    public var label: IdleEpisodeLabel

    public init(episodeID: UUID, timestamp: Date = Date(), label: IdleEpisodeLabel) {
        self.episodeID = episodeID
        self.timestamp = timestamp
        self.label = label
    }
}
