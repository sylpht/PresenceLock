import Foundation

/// Camera estimates for completed pauses that have no human feedback.
public struct PassiveEpisodeSummary: Equatable, Sendable {
    public let likelyPresent: Int
    public let likelyAway: Int
    public let uncertain: Int
    public let presentIdleMedian: TimeInterval?
    public let presentIdleP90: TimeInterval?
    public let presentIdleMaximum: TimeInterval?
}

public enum PassiveEpisodeAnalysis {
    private enum Estimate {
        case likelyPresent, likelyAway, uncertain
    }

    public static func summarize(
        records: [ObservationRecord],
        episodeFeedback: [IdleEpisodeFeedback] = [],
        predictionFeedback: [PredictionFeedback] = []
    ) -> PassiveEpisodeSummary {
        let labeledEpisodes = Set(episodeFeedback.map(\.episodeID))
        let labeledPredictions = Set(predictionFeedback.map(\.predictionID))
        var presentDurations: [TimeInterval] = []
        var away = 0
        var uncertain = 0
        var episode: [ObservationRecord] = []

        // Stable timestamp sort retains the append order for events in the same second.
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch record.event {
            case "idleStarted":
                episode = [record]
            case "idleUnanchored", "sessionBoundary", "episodeBoundary", "inputAnchor":
                episode.removeAll(keepingCapacity: true)
            case "inputResumed":
                defer { episode.removeAll(keepingCapacity: true) }
                guard !episode.isEmpty, !labeledEpisodes.contains(record.id),
                      !episode.contains(where: { labeledPredictions.contains($0.id) }) else { continue }
                episode.append(record)
                switch estimate(episode) {
                case .likelyPresent: presentDurations.append(record.idleSeconds)
                case .likelyAway: away += 1
                case .uncertain: uncertain += 1
                case nil: break
                }
            default:
                if !episode.isEmpty { episode.append(record) }
            }
        }

        return PassiveEpisodeSummary(
            likelyPresent: presentDurations.count,
            likelyAway: away,
            uncertain: uncertain,
            presentIdleMedian: StatisticsEngine.percentile(presentDurations, probability: 0.5),
            presentIdleP90: StatisticsEngine.percentile(presentDurations, probability: 0.9),
            presentIdleMaximum: presentDurations.max()
        )
    }

    private static func estimate(_ episode: [ObservationRecord]) -> Estimate? {
        guard let start = episode.first?.replayTick, let config = start.configuration,
              let end = episode.last, end.state == .active, end.replayTick?.inputOccurred == true,
              end.idleSeconds.isFinite, end.idleSeconds >= config.probeIdleSeconds else { return nil }

        let lastInputTime = start.monotonicTime - start.idleSeconds
        let probeTime = lastInputTime + config.probeIdleSeconds
        let maximumPresenceGap = config.maximumSampleAgeSeconds + 2 * config.sampleIntervalSeconds
        let warmupAllowance = config.maximumUpdateGapSeconds + 2 * config.sampleIntervalSeconds
        var previousTick: DecisionReplayTick?
        var lastCapture: TimeInterval?
        var firstPresence: TimeInterval?
        var latestPresence: TimeInterval?
        var longestPresenceGap: TimeInterval = 0
        var observedFrames = 0
        var presentFrames = 0
        var absentStart: TimeInterval?
        var absentFrames = 0
        var sawSustainedAbsence = false
        var returnTime: TimeInterval = 0

        for record in episode {
            guard let tick = record.replayTick else {
                // Companion action rows have no separate frame or decision tick.
                guard record.event != nil else { return nil }
                continue
            }
            guard let evidence = tick.cameraEvidence, tick.cameraPreviewActive != true,
                  tick.monotonicTime.isFinite, tick.idleSeconds.isFinite, tick.idleSeconds >= 0,
                  tick.updateGapSeconds.isFinite, tick.updateGapSeconds >= 0,
                  tick.updateGapSeconds <= config.maximumUpdateGapSeconds else { return nil }
            if let previousTick {
                let elapsed = tick.monotonicTime - previousTick.monotonicTime
                guard elapsed > 0, abs(elapsed - tick.updateGapSeconds) < 0.001 else { return nil }
            }
            if tick.inputOccurred {
                guard record.event == "inputResumed", let previousTick,
                      abs(previousTick.idleSeconds - end.idleSeconds) <= config.maximumUpdateGapSeconds
                else { return nil }
                // The input closes the pause. Its camera frame may already show the return.
                returnTime = tick.monotonicTime - tick.idleSeconds
                break
            }
            // A new input can fall between two polls even if the idle counter does not
            // decrease. The presumed time of the last input must stay stable in a pause.
            guard abs((tick.monotonicTime - tick.idleSeconds) - lastInputTime) <= 0.25 else { return nil }
            previousTick = tick
            guard tick.idleSeconds >= config.probeIdleSeconds else { continue }

            guard record.cameraAvailable, let age = record.readingAgeSeconds, age.isFinite, age >= 0,
                  age <= config.maximumSampleAgeSeconds else {
                absentStart = nil
                absentFrames = 0
                continue
            }
            let capture = tick.monotonicTime - age
            guard capture >= probeTime else { continue }
            if evidence.sawPresence || evidence.sawUncertainty || record.observation != .absent {
                absentStart = nil
                absentFrames = 0
            }
            if let lastCapture {
                guard capture >= lastCapture - 0.001 else { return nil }
                if capture - lastCapture < 0.001 { continue }
                if capture - lastCapture > config.maximumSampleAgeSeconds {
                    absentStart = nil
                    absentFrames = 0
                }
            }
            lastCapture = capture
            // Some cameras supply an explicitly unusable frame while warming up.
            // The first-presence deadline below bounds this initial blind interval.
            if observedFrames == 0, record.observation == .unknown { continue }
            observedFrames += 1
            if record.observation == .present, !evidence.sawUncertainty {
                if let latestPresence { longestPresenceGap = max(longestPresenceGap, capture - latestPresence) }
                firstPresence = firstPresence ?? capture
                latestPresence = capture
                presentFrames += 1
            } else if record.observation == .absent, !evidence.sawPresence, !evidence.sawUncertainty {
                let startOfRun = absentStart ?? capture
                absentStart = startOfRun
                absentFrames += 1
                if absentFrames >= 3,
                   capture - startOfRun >= max(config.absenceConfirmationSeconds, 3 * config.sampleIntervalSeconds) {
                    sawSustainedAbsence = true
                }
            }
        }

        if sawSustainedAbsence { return .likelyAway }
        // Allow a short camera startup and isolated misses while still requiring that
        // fresh positive detections cover the observed pause all the way back to input.
        guard let firstPresence, let latestPresence, presentFrames >= 3,
              latestPresence - firstPresence >= 2 * config.sampleIntervalSeconds,
              firstPresence - probeTime <= warmupAllowance,
              returnTime >= latestPresence, returnTime - latestPresence <= config.maximumSampleAgeSeconds,
              longestPresenceGap <= maximumPresenceGap,
              Double(presentFrames) / Double(observedFrames) >= 0.95 else { return .uncertain }
        return .likelyPresent
    }
}
