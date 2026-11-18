import Foundation

public struct ThresholdCandidate: Codable, Equatable, Sendable {
    public let probeIdleSeconds: TimeInterval
    public let absenceConfirmationSeconds: TimeInterval
    public let warningSeconds: TimeInterval

    public init(
        probeIdleSeconds: TimeInterval,
        absenceConfirmationSeconds: TimeInterval,
        warningSeconds: TimeInterval = 5
    ) {
        self.probeIdleSeconds = Self.validated(probeIdleSeconds, fallback: 8)
        self.absenceConfirmationSeconds = Self.validated(absenceConfirmationSeconds, fallback: 20)
        self.warningSeconds = Self.validated(warningSeconds, fallback: 5)
    }

    private static func validated(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        value.isFinite ? max(1, value) : fallback
    }
}

public struct ThresholdEvaluation: Codable, Equatable, Sendable {
    public let candidate: ThresholdCandidate
    public let eligibleEpisodes: Int
    public let labeledEpisodes: Int
    public let conflictingEpisodes: Int
    public let confirmedDepartures: Int
    public let confirmedDeparturesCaught: Int
    public let falseAlarmEpisodes: Int
    public let falseAlarmsTriggered: Int
    public let unlabeledPredictions: Int
    public let medianDetectionLatency: TimeInterval?
    public let estimatedCameraSeconds: TimeInterval
    public let trackedEpisodes: Int
    public let legacyEpisodes: Int
    public let episodesWithNewCountdownEvidence: Int
    public let excludedEpisodes: Int
    public let departuresWithUnknownTiming: Int
    public let departuresWithUnknownTimingWithoutPrediction: Int

    public var labeledEpisodeCount: Int { labeledEpisodes }
}

public struct DecisionReplayVerification: Equatable, Sendable {
    public let checkedEpisodes: Int
    public let matchingEpisodes: Int
    public let recordedPredictions: Int
    public let replayedPredictions: Int
    public let incompleteTraces: Int
    public let checkedOpenEpisodes: Int
}

public struct PosePolicyComparison: Equatable, Sendable {
    public fileprivate(set) var episodes = 0
    public fileprivate(set) var baselineWarnings = 0
    public fileprivate(set) var candidateWarnings = 0
    public fileprivate(set) var baselinePredictions = 0
    public fileprivate(set) var candidatePredictions = 0
    public fileprivate(set) var medianFirstPredictionDelay: TimeInterval?
}

public enum ThresholdReplay {
    /// Both policies see exactly the same recorded inputs and thresholds. Corroborating
    /// pose observations can interrupt simulated absence but never establish identity or presence.
    public static func comparePoseShadow(
        records: [ObservationRecord], summary: PoseShadowSummary
    ) -> PosePolicyComparison {
        var comparison = PosePolicyComparison()
        guard !summary.sampledEpisodeStartIDs.isEmpty else { return comparison }
        let episodes = makeEpisodes(records: records, feedback: [], episodeFeedback: [], maximumGap: 6)
        var firstPredictionDelays: [TimeInterval] = []
        for episode in episodes {
            guard episode.isComplete, episode.startsWithKnownInput,
                  let id = episode.records.first?.id, summary.sampledEpisodeStartIDs.contains(id),
                  let config = episode.referenceConfiguration,
                  let warnings = referenceActionTimes(in: episode.records, events: ["warningStarted"]),
                  let predictions = referenceActionTimes(in: episode.records) else { continue }
            let baseline = run(episode, configuration: config)
            guard baseline.warningTimes == warnings,
                  baseline.predictions.map(\.monotonicTime) == predictions else { continue }
            let candidate = run(episode, configuration: config, poseVetoTickIDs: summary.corroboratedTickIDs)
            comparison.episodes += 1
            comparison.baselineWarnings += baseline.warningTimes.count
            comparison.candidateWarnings += candidate.warningTimes.count
            comparison.baselinePredictions += baseline.predictions.count
            comparison.candidatePredictions += candidate.predictions.count
            if let first = baseline.predictions.first, let other = candidate.predictions.first {
                firstPredictionDelays.append(other.monotonicTime - first.monotonicTime)
            }
        }
        comparison.medianFirstPredictionDelay = StatisticsEngine.percentile(firstPredictionDelays, probability: 0.5)
        return comparison
    }

    public static func defaultGrid(
        minimumProbeSeconds: TimeInterval = 8,
        currentConfiguration: DetectionConfiguration? = nil
    ) -> [ThresholdCandidate] {
        var probes = [8.0, 15, 30, 60].filter { $0 >= minimumProbeSeconds }
        if let probe = currentConfiguration?.probeIdleSeconds, !probes.contains(probe) {
            probes.append(probe)
            probes.sort()
        }
        let confirmations = [10.0, 15, 20, 30, 45]
        var candidates = probes.flatMap { probe in
            confirmations.map {
                ThresholdCandidate(
                    probeIdleSeconds: probe,
                    absenceConfirmationSeconds: $0,
                    warningSeconds: currentConfiguration?.warningSeconds ?? 5
                )
            }
        }
        if let currentConfiguration {
            let current = ThresholdCandidate(
                probeIdleSeconds: currentConfiguration.probeIdleSeconds,
                absenceConfirmationSeconds: currentConfiguration.absenceConfirmationSeconds,
                warningSeconds: currentConfiguration.warningSeconds
            )
            if !candidates.contains(current) { candidates.append(current) }
        }
        return candidates.sorted {
            if $0.probeIdleSeconds != $1.probeIdleSeconds {
                return $0.probeIdleSeconds < $1.probeIdleSeconds
            }
            if $0.absenceConfirmationSeconds != $1.absenceConfirmationSeconds {
                return $0.absenceConfirmationSeconds < $1.absenceConfirmationSeconds
            }
            return $0.warningSeconds < $1.warningSeconds
        }
    }

    public static func evaluate(
        records: [ObservationRecord],
        feedback: [PredictionFeedback],
        episodeFeedback: [IdleEpisodeFeedback] = [],
        candidates: [ThresholdCandidate],
        maximumEpisodeGap: TimeInterval = 6,
        includeLegacy: Bool = true
    ) -> [ThresholdEvaluation] {
        let episodes = makeEpisodes(
            records: records,
            feedback: feedback,
            episodeFeedback: episodeFeedback,
            maximumGap: maximumEpisodeGap
        )
        guard let cohortProbe = candidates.map(\.probeIdleSeconds).min() else { return [] }
        let potentialCohort = episodes.filter { episode in
            (episode.records.map(\.idleSeconds).max() ?? 0) >= cohortProbe
        }
        let commonCohort = potentialCohort.filter { episode in
            if !episode.usesRichLogging { return includeLegacy }
            // A preview can prewarm the camera before the normal capture threshold.
            // Exclude the entire episode even if the preview closed before the probe.
            guard !episode.records.contains(where: { $0.replayTick?.cameraPreviewActive == true }) else {
                return false
            }
            // The recording cannot tell us what the camera would have seen if asked to
            // start earlier. Exclude these episodes from all rows to keep the cohort common.
            guard let configuration = episode.referenceConfiguration,
                  configuration.probeIdleSeconds <= cohortProbe,
                  let recorded = referenceActionTimes(in: episode.records) else { return false }
            return run(episode, configuration: configuration).predictions.map(\.monotonicTime) == recorded
        }
        return candidates.map {
            evaluate($0, episodes: commonCohort, excludedEpisodes: potentialCohort.count - commonCohort.count)
        }
    }

    public static func verifyReferenceDecisions(
        records: [ObservationRecord],
        maximumEpisodeGap: TimeInterval = 6
    ) -> DecisionReplayVerification {
        let episodes = makeEpisodes(
            records: records,
            feedback: [],
            episodeFeedback: [],
            maximumGap: maximumEpisodeGap
        )
        var checked = 0
        var matching = 0
        var recorded = 0
        var replayed = 0
        var incomplete = 0
        var checkedOpen = 0
        for episode in episodes where episode.usesRichLogging {
            guard let configuration = episode.referenceConfiguration,
                  let observed = referenceActionTimes(in: episode.records) else {
                incomplete += 1
                continue
            }
            guard episode.records.contains(where: {
                ($0.replayTick?.idleSeconds ?? 0) >= configuration.probeIdleSeconds
                    && $0.replayTick?.inputOccurred == false
            }) else { continue }
            let isClosed = episode.isComplete || episode.records.last.map(isBoundary) == true
            // An open tail tells us nothing about a decision that may still be pending.
            // Once a decision is recorded we can verify it through the last observed tick.
            guard isClosed || !observed.isEmpty else { continue }
            let replay = run(episode, configuration: configuration)
            let predicted = replay.predictions.map(\.monotonicTime)
            checked += 1
            if !isClosed { checkedOpen += 1 }
            recorded += observed.count
            replayed += predicted.count
            if observed == predicted { matching += 1 }
        }
        return DecisionReplayVerification(
            checkedEpisodes: checked,
            matchingEpisodes: matching,
            recordedPredictions: recorded,
            replayedPredictions: replayed,
            incompleteTraces: incomplete,
            checkedOpenEpisodes: checkedOpen
        )
    }

    private struct Episode {
        var records: [ObservationRecord]
        var startsWithKnownInput: Bool
        var isComplete: Bool
        var falseThroughIdle: TimeInterval?
        var departureConfirmedByIdle: TimeInterval?
        var departureWithoutTiming: Bool
        var hasAnyLabel: Bool
        var hasConflictingLabels: Bool
        var usesRichLogging: Bool
        var usesNewCountdownEvidence: Bool
        var referenceConfiguration: DetectionConfiguration?
    }

    private static func makeEpisodes(
        records: [ObservationRecord],
        feedback: [PredictionFeedback],
        episodeFeedback: [IdleEpisodeFeedback],
        maximumGap: TimeInterval
    ) -> [Episode] {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        var latestFeedback: [UUID: PredictionFeedback] = [:]
        for item in feedback.sorted(by: { $0.timestamp < $1.timestamp }) {
            latestFeedback[item.predictionID] = item
        }
        var latestEpisodeFeedback: [UUID: IdleEpisodeFeedback] = [:]
        for item in episodeFeedback.sorted(by: { $0.timestamp < $1.timestamp }) {
            latestEpisodeFeedback[item.episodeID] = item
        }

        var episodes: [Episode] = []
        var current: [ObservationRecord] = []
        var currentStartsWithKnownInput = false
        var previous: ObservationRecord?

        func finish(completed: Bool) {
            guard !current.isEmpty else { return }
            defer { current.removeAll(keepingCapacity: true) }
            if current.count == 1, current.first?.event == "inputAnchor" { return }
            let predictionLabels = current.compactMap { record -> (ObservationRecord, PredictionFeedback)? in
                guard let label = latestFeedback[record.id] else { return nil }
                return (record, label)
            }
            let episodeLabels = current.compactMap { latestEpisodeFeedback[$0.id] }
            let stayedPresent = episodeLabels.contains { $0.label == .stayedPresent }
            let falseTimes = predictionLabels.compactMap { record, label in
                label.label == .falseAlarm ? record.idleSeconds : nil
            }
            let departureTimes = predictionLabels.compactMap { record, label in
                label.label == .confirmedDeparture ? record.idleSeconds : nil
            }
            let maximumIdle = current.map(\.idleSeconds).max()
            let falseThrough = stayedPresent ? maximumIdle : falseTimes.max()
            let departureBy = departureTimes.min()
            let markedDeparture = episodeLabels.contains { $0.label == .departed }
            let incompatibleTiming = falseThrough.flatMap { end in departureBy.map { end >= $0 } } ?? false
            let conflicting = (stayedPresent && (departureBy != nil || markedDeparture)) || incompatibleTiming
            let usesRichLogging = current.contains { $0.replayTick != nil || isTraceHeader($0) }

            episodes.append(Episode(
                records: current,
                startsWithKnownInput: currentStartsWithKnownInput,
                isComplete: completed,
                falseThroughIdle: conflicting ? nil : falseThrough,
                departureConfirmedByIdle: conflicting ? nil : departureBy,
                departureWithoutTiming: markedDeparture && departureBy == nil && !conflicting,
                hasAnyLabel: !predictionLabels.isEmpty || !episodeLabels.isEmpty,
                hasConflictingLabels: conflicting,
                usesRichLogging: usesRichLogging,
                usesNewCountdownEvidence: current.first?.replayTick?.cameraEvidence != nil,
                referenceConfiguration: referenceConfiguration(in: current)
            ))
        }

        for record in sorted {
            // macOS can return its result after unrelated input or even a session boundary.
            if record.isLockRequestDiagnostic { continue }
            if let previous, previous.timestamp == record.timestamp,
               previous.replayTick?.inputOccurred == true,
               record.event == "warningCancelled", record.replayTick == nil {
                continue
            }
            if isTraceHeader(record) {
                finish(completed: false)
                currentStartsWithKnownInput = record.event == "idleStarted"
            } else if let previous, record.replayTick == nil, current.first?.replayTick == nil {
                let gap = record.timestamp.timeIntervalSince(previous.timestamp)
                let idleReset = record.idleSeconds + maximumGap < previous.idleSeconds
                if gap < 0 || gap > maximumGap || idleReset {
                    let resetProvesCompletion = gap >= 0 && gap <= maximumGap && idleReset
                    finish(completed: resetProvesCompletion)
                    currentStartsWithKnownInput = gap >= 0 && gap <= maximumGap && idleReset
                }
            }

            current.append(record)
            let resumedInput = record.event == "inputResumed"
                || record.event == "inputAnchor"
                || record.replayTick?.inputOccurred == true
                || (record.replayTick?.idleSeconds ?? record.idleSeconds) < 1
            if isBoundary(record) || resumedInput {
                let isLegacy = current.first?.replayTick == nil && record.replayTick == nil
                finish(completed: !isBoundary(record) || isLegacy)
                currentStartsWithKnownInput = !isBoundary(record) && resumedInput
            }
            previous = record
        }
        finish(completed: false)
        return episodes
    }

    private static func isTraceHeader(_ record: ObservationRecord) -> Bool {
        record.event == "idleStarted" || record.event == "idleUnanchored"
    }

    private static func isBoundary(_ record: ObservationRecord) -> Bool {
        record.event == "episodeBoundary" || record.event == "sessionBoundary"
    }

    private static func referenceConfiguration(in records: [ObservationRecord]) -> DetectionConfiguration? {
        guard let header = records.first, isTraceHeader(header),
              let firstTick = header.replayTick,
              let configuration = firstTick.configuration else { return nil }

        let usesNewCountdownEvidence = firstTick.cameraEvidence != nil
        var previousTime: TimeInterval?
        for record in records {
            guard let tick = record.replayTick else { continue }
            guard tick.monotonicTime.isFinite, tick.monotonicTime >= 0,
                  tick.updateGapSeconds.isFinite, tick.updateGapSeconds >= 0,
                  tick.idleSeconds.isFinite, tick.idleSeconds >= 0,
                  (tick.cameraEvidence != nil) == usesNewCountdownEvidence,
                  record.readingAgeSeconds?.isFinite == true else { return nil }

            if let previousTime {
                let elapsed = tick.monotonicTime - previousTime
                // A missing record must not silently fill part of an absence countdown.
                guard elapsed > 0, abs(elapsed - tick.updateGapSeconds) < 0.001 else { return nil }
            }
            previousTime = tick.monotonicTime
        }
        return configuration
    }

    private static func referenceActionTimes(
        in records: [ObservationRecord], events: Set<String> = ["wouldLock", "lock"]
    ) -> [TimeInterval]? {
        var times: [TimeInterval] = []
        var lastTick: ObservationRecord?
        for record in records {
            if record.replayTick != nil { lastTick = record }
            guard let event = record.event, events.contains(event) else { continue }
            // A decision on the header tick is written as a second event for that same tick.
            guard let lastTick, lastTick.timestamp == record.timestamp,
                  let time = lastTick.replayTick?.monotonicTime else { return nil }
            times.append(time)
        }
        return times
    }

    private static func evaluate(
        _ candidate: ThresholdCandidate,
        episodes: [Episode],
        excludedEpisodes: Int
    ) -> ThresholdEvaluation {
        var eligibleEpisodes = 0
        var labeledEpisodes = 0
        var conflictingEpisodes = 0
        var confirmedDepartures = 0
        var confirmedCaught = 0
        var falseAlarmEpisodes = 0
        var falseTriggered = 0
        var unlabeledPredictions = 0
        var latencies: [TimeInterval] = []
        var cameraSeconds: TimeInterval = 0
        var trackedEpisodes = 0
        var legacyEpisodes = 0
        var episodesWithNewCountdownEvidence = 0
        var departuresWithUnknownTiming = 0
        var departuresWithUnknownTimingWithoutPrediction = 0

        for episode in episodes {
            let hasTimedOutcome = episode.falseThroughIdle != nil
                || episode.departureConfirmedByIdle != nil
            let hasOutcome = episode.isComplete || hasTimedOutcome
            if hasOutcome {
                eligibleEpisodes += 1
                if episode.usesRichLogging { trackedEpisodes += 1 } else { legacyEpisodes += 1 }
                if episode.usesNewCountdownEvidence { episodesWithNewCountdownEvidence += 1 }
                if episode.hasAnyLabel { labeledEpisodes += 1 }
                if episode.hasConflictingLabels { conflictingEpisodes += 1 }
                if episode.departureConfirmedByIdle != nil { confirmedDepartures += 1 }
                if episode.falseThroughIdle != nil { falseAlarmEpisodes += 1 }
                if episode.departureWithoutTiming && episode.isComplete { departuresWithUnknownTiming += 1 }
            }

            let configuration = DetectionConfiguration(
                probeIdleSeconds: candidate.probeIdleSeconds,
                absenceConfirmationSeconds: candidate.absenceConfirmationSeconds,
                warningSeconds: candidate.warningSeconds,
                maximumSampleAgeSeconds: episode.referenceConfiguration?.maximumSampleAgeSeconds ?? 3,
                maximumUpdateGapSeconds: episode.referenceConfiguration?.maximumUpdateGapSeconds ?? 6,
                sampleIntervalSeconds: episode.referenceConfiguration?.sampleIntervalSeconds ?? 2
            )
            let replay = run(episode, configuration: configuration)
            cameraSeconds += replay.cameraSeconds

            guard let prediction = replay.predictions.first else {
                if episode.departureWithoutTiming && episode.isComplete {
                    departuresWithUnknownTimingWithoutPrediction += 1
                }
                continue
            }
            if let falseThrough = episode.falseThroughIdle, prediction.idleSeconds <= falseThrough {
                falseTriggered += 1
            } else if let departureBy = episode.departureConfirmedByIdle, prediction.idleSeconds >= departureBy {
                confirmedCaught += 1
                if let latency = prediction.latency {
                    latencies.append(latency)
                }
            } else {
                // A coarse "departed sometime" label has no onset timestamp. A trigger before
                // a separately confirmed departure could still have been premature.
                unlabeledPredictions += 1
            }
        }

        return ThresholdEvaluation(
            candidate: candidate,
            eligibleEpisodes: eligibleEpisodes,
            labeledEpisodes: labeledEpisodes,
            conflictingEpisodes: conflictingEpisodes,
            confirmedDepartures: confirmedDepartures,
            confirmedDeparturesCaught: confirmedCaught,
            falseAlarmEpisodes: falseAlarmEpisodes,
            falseAlarmsTriggered: falseTriggered,
            unlabeledPredictions: unlabeledPredictions,
            medianDetectionLatency: StatisticsEngine.percentile(latencies, probability: 0.5),
            estimatedCameraSeconds: cameraSeconds,
            trackedEpisodes: trackedEpisodes,
            legacyEpisodes: legacyEpisodes,
            episodesWithNewCountdownEvidence: episodesWithNewCountdownEvidence,
            excludedEpisodes: excludedEpisodes,
            departuresWithUnknownTiming: departuresWithUnknownTiming,
            departuresWithUnknownTimingWithoutPrediction: departuresWithUnknownTimingWithoutPrediction
        )
    }

    private struct ReplayPrediction {
        let idleSeconds: TimeInterval
        let monotonicTime: TimeInterval
        let latency: TimeInterval?
    }

    private struct ReplayRun {
        var predictions: [ReplayPrediction] = []
        var warningTimes: [TimeInterval] = []
        var cameraSeconds: TimeInterval = 0
    }

    private static func run(
        _ episode: Episode, configuration: DetectionConfiguration, poseVetoTickIDs: Set<UUID> = []
    ) -> ReplayRun {
        let machine = PresenceStateMachine(
            mode: .learning,
            configuration: configuration,
            requirePostWarningFrame: episode.usesNewCountdownEvidence
        )
        if episode.startsWithKnownInput { machine.acknowledgePresence() }

        var result = ReplayRun()
        var previousTime: TimeInterval?
        var activeAbsentStartedAt: TimeInterval?
        var firstCandidateProbe: TimeInterval?
        var cameraStartedAt: TimeInterval?
        var cameraLastSeenAt: TimeInterval?
        let laterProbe = episode.referenceConfiguration.map {
            configuration.probeIdleSeconds > $0.probeIdleSeconds
        } ?? false

        for record in episode.records {
            if isBoundary(record) { continue }
            if record.event == "warningAcknowledged" {
                machine.acknowledgePresence()
                activeAbsentStartedAt = nil
                continue
            }
            let tick = record.replayTick
            if episode.usesRichLogging && tick == nil { continue }

            let monotonic = tick?.monotonicTime ?? max(previousTime ?? 0, record.idleSeconds)
            let idle = tick?.idleSeconds ?? record.idleSeconds
            let gap = tick?.updateGapSeconds ?? previousTime.map { max(0, monotonic - $0) } ?? 0
            let inputOccurred = tick?.inputOccurred ?? (record.event == "inputResumed")
            previousTime = monotonic

            if !inputOccurred && idle >= configuration.probeIdleSeconds {
                firstCandidateProbe = firstCandidateProbe ?? monotonic
                let sampleTime = tick == nil ? record.timestamp.timeIntervalSinceReferenceDate : monotonic
                cameraStartedAt = cameraStartedAt ?? sampleTime
                cameraLastSeenAt = sampleTime
            }

            let readingAge = tick == nil ? max(0, record.readingAgeSeconds ?? 0) : record.readingAgeSeconds ?? 0
            let captureTime = monotonic - readingAge
            // A delayed candidate must not reuse data captured before its hypothetical start.
            // The warm-up and changed Vision sampling cadence still need a live shadow test.
            let predatesCandidateStart = laterProbe && firstCandidateProbe.map { captureTime < $0 } == true
            // This batch spans the interval ending at the current poll. A later
            // candidate's camera would only begin capturing at its first probe.
            let isLaterCandidateFirstProbe = laterProbe && firstCandidateProbe == monotonic
            var cameraEvidence: CameraTickEvidence = isLaterCandidateFirstProbe
                ? .none
                : tick?.cameraEvidence ?? .none
            if poseVetoTickIDs.contains(record.id) {
                cameraEvidence.sawUncertainty = true
            }
            let reading = PresenceReading(
                observation: predatesCandidateStart ? .unknown : record.observation,
                confidence: record.confidence,
                capturedAt: record.timestamp.addingTimeInterval(-readingAge),
                capturedAtMonotonic: captureTime,
                cameraAvailable: record.cameraAvailable
            )
            let actions = machine.update(StateMachineInput(
                now: record.timestamp,
                monotonicNow: monotonic,
                idleSeconds: idle,
                inputOccurred: inputOccurred,
                updateGapSeconds: gap,
                reading: reading,
                cameraEvidence: cameraEvidence
            ))
            if actions.contains(.warningStarted) { result.warningTimes.append(monotonic) }
            switch machine.state {
            case .suspectedAway, .warning, .triggered:
                activeAbsentStartedAt = activeAbsentStartedAt ?? monotonic
            default:
                activeAbsentStartedAt = nil
            }
            if actions.contains(.wouldLock) {
                result.predictions.append(ReplayPrediction(
                    idleSeconds: idle,
                    monotonicTime: monotonic,
                    latency: activeAbsentStartedAt.map { max(0, monotonic - $0) }
                ))
            }
        }
        if let start = cameraStartedAt, let end = cameraLastSeenAt {
            result.cameraSeconds = max(0, end - start)
        }
        return result
    }
}
