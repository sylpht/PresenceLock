import Foundation

public struct DurationSummary: Codable, Equatable, Sendable {
    public var count: Int
    public var rightCensoredCount: Int
    public var median: TimeInterval?
    public var p90: TimeInterval?
    public var p95: TimeInterval?
    public var p99: TimeInterval?
    public var maximum: TimeInterval?
}

public struct LearningSummary: Codable, Equatable, Sendable {
    public var firstSampleAt: Date?
    public var lastSampleAt: Date?
    public var sampleCount: Int
    public var confirmedPresentIdleEpisodes: DurationSummary
    public var presentIdleRuns: DurationSummary
    public var absenceRuns: DurationSummary
    public var predictedLocks: Int
    public var confirmedDepartures: Int
    public var falseAlarms: Int
}

public enum StatisticsEngine {
    public static func summarize(
        records: [ObservationRecord],
        feedback: [PredictionFeedback] = [],
        episodeFeedback: [IdleEpisodeFeedback] = [],
        maximumGap: TimeInterval = 5,
        probeIdleSeconds: TimeInterval = 8
    ) -> LearningSummary {
        let sorted = records.sorted { $0.timestamp < $1.timestamp }
        let cameraRecords = ordinaryCameraRecords(in: sorted)
        let presentRuns = presentIdleDurations(
            in: cameraRecords,
            maximumGap: maximumGap,
            probeIdleSeconds: probeIdleSeconds
        )
        let absenceRuns = runDurations(in: cameraRecords, matching: .absent, maximumGap: maximumGap)
        let predictions = sorted.filter { $0.event == "wouldLock" || $0.event == "lock" }
        let predictionIDs = Set(predictions.map(\.id))
        var latestFeedback: [UUID: PredictionFeedback] = [:]
        for item in feedback.sorted(by: { $0.timestamp < $1.timestamp }) where predictionIDs.contains(item.predictionID) {
            latestFeedback[item.predictionID] = item
        }

        return LearningSummary(
            firstSampleAt: sorted.first?.timestamp,
            lastSampleAt: sorted.last?.timestamp,
            sampleCount: sorted.count,
            confirmedPresentIdleEpisodes: durationSummary(
                confirmedPresentIdleDurations(in: sorted, feedback: episodeFeedback),
                rightCensoredCount: 0
            ),
            presentIdleRuns: censoredDurationSummary(presentRuns),
            absenceRuns: durationSummary(absenceRuns, rightCensoredCount: 0),
            predictedLocks: predictions.count,
            confirmedDepartures: latestFeedback.values.filter { $0.label == .confirmedDeparture }.count,
            falseAlarms: latestFeedback.values.filter { $0.label == .falseAlarm }.count
        )
    }

    /// Normalize physical camera observations once for both timing summaries. A preview
    /// prewarms the camera even if it was closed before the first ordinary reading.
    private static func ordinaryCameraRecords(in records: [ObservationRecord]) -> [ObservationRecord] {
        var ordinary: [ObservationRecord] = []
        var start = records.startIndex
        var preview = false
        var maximumAge = DetectionConfiguration.learningDefault.maximumSampleAgeSeconds
        var lastTickTime: Date?

        func appendPause(endingAt end: Int) {
            guard start < end else { return }
            if preview {
                // Keep a censoring boundary so adjacent ordinary spells cannot join.
                var boundary = records[start]
                boundary.event = "sessionBoundary"
                boundary.observation = .unknown
                ordinary.append(boundary)
                return
            }
            var previousCapture: TimeInterval?
            var hasDetailedTicks = false
            for var record in records[start..<end] {
                if record.isLockRequestDiagnostic { continue }
                let tick = record.replayTick
                if let config = tick?.configuration { maximumAge = config.maximumSampleAgeSeconds }
                if tick != nil {
                    hasDetailedTicks = true
                    lastTickTime = record.timestamp
                }
                switch record.event {
                case "episodeBoundary", "sessionBoundary", "inputAnchor", "inputResumed":
                    // These rows terminate an interval; the cached camera result on them
                    // is not another independent observation of the empty chair.
                    record.observation = .unknown
                    ordinary.append(record)
                    continue
                default:
                    if tick == nil, hasDetailedTicks || record.timestamp == lastTickTime { continue }
                }
                if !record.cameraAvailable || tick?.cameraEvidence?.sawUncertainty == true
                    || (record.observation == .absent && tick?.cameraEvidence?.sawPresence == true) {
                    record.observation = .unknown
                }
                if let age = record.readingAgeSeconds {
                    if !age.isFinite || age < 0 || age > maximumAge {
                        record.observation = .unknown
                    } else if let tick, record.observation != .unknown {
                        let capture = tick.monotonicTime - age
                        if let previousCapture, abs(capture - previousCapture) < 0.001 { continue }
                        previousCapture = capture
                        record.idleSeconds = max(0, record.idleSeconds - age)
                        record.timestamp = record.timestamp.addingTimeInterval(-age)
                    }
                } else if tick != nil {
                    record.observation = .unknown
                }
                ordinary.append(record)
            }
        }

        for index in records.indices {
            let record = records[index]
            if record.event == "idleStarted" || record.event == "idleUnanchored" {
                appendPause(endingAt: index)
                start = index
                preview = false
            }
            if record.replayTick?.cameraPreviewActive == true { preview = true }
            switch record.event {
            case "inputResumed", "inputAnchor", "episodeBoundary", "sessionBoundary":
                appendPause(endingAt: index + 1)
                start = index + 1
                preview = false
            default: break
            }
        }
        appendPause(endingAt: records.endIndex)
        return ordinary
    }

    private static func confirmedPresentIdleDurations(
        in records: [ObservationRecord],
        feedback: [IdleEpisodeFeedback]
    ) -> [TimeInterval] {
        var latestFeedback: [UUID: IdleEpisodeFeedback] = [:]
        for item in feedback {
            if let previous = latestFeedback[item.episodeID], previous.timestamp > item.timestamp {
                continue
            }
            // Journal order resolves corrections within the same timestamp second.
            latestFeedback[item.episodeID] = item
        }

        var durations: [TimeInterval] = []
        var lastBoundary: Date?
        for record in records {
            if record.event == "episodeBoundary" || record.event == "sessionBoundary" {
                lastBoundary = record.timestamp
                continue
            }
            // inputResumed stores the pre-input idle duration. Manual feedback on this
            // completed episode covers camera warm-up and later gaps in vision coverage.
            guard record.event == "inputResumed", record.state == .active,
                  record.idleSeconds.isFinite, record.idleSeconds > 0,
                  latestFeedback[record.id]?.label == .stayedPresent else { continue }

            let start = record.timestamp.addingTimeInterval(-record.idleSeconds)
            if let lastBoundary, lastBoundary > start { continue }
            durations.append(record.idleSeconds)
            latestFeedback.removeValue(forKey: record.id)
        }
        return durations
    }

    public static func percentile(_ values: [TimeInterval], probability: Double) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let p = min(max(probability, 0), 1)
        let position = p * Double(sorted.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sorted[lowerIndex] }
        let weight = position - Double(lowerIndex)
        return sorted[lowerIndex] * (1 - weight) + sorted[upperIndex] * weight
    }

    private static func runDurations(
        in records: [ObservationRecord],
        matching observation: PresenceObservation,
        maximumGap: TimeInterval
    ) -> [TimeInterval] {
        var durations: [TimeInterval] = []
        var runStart: Date?
        var previous: ObservationRecord?

        func finish(at end: Date?) {
            guard let start = runStart, let end, end >= start else {
                runStart = nil
                return
            }
            durations.append(end.timeIntervalSince(start))
            runStart = nil
        }

        for record in records {
            let isMatch = record.observation == observation && record.idleSeconds >= 1
            let isContinuous: Bool
            if let previous {
                let gap = record.timestamp.timeIntervalSince(previous.timestamp)
                let idleDidNotReset = record.idleSeconds + maximumGap >= previous.idleSeconds
                isContinuous = gap >= 0 && gap <= maximumGap && idleDidNotReset
            } else {
                isContinuous = false
            }

            if isMatch {
                if runStart == nil || !isContinuous {
                    finish(at: previous?.timestamp)
                    runStart = record.timestamp
                }
            } else {
                finish(at: previous?.timestamp)
            }
            previous = record
        }

        finish(at: previous?.timestamp)
        return durations.filter { $0 > 0 }
    }

    /// Reconstructs the user's full input-idle duration from the idle counter rather than
    /// measuring only the camera-on suffix of the episode.
    private struct DurationObservation {
        var duration: TimeInterval
        var isRightCensored: Bool
    }

    private static func presentIdleDurations(
        in records: [ObservationRecord],
        maximumGap: TimeInterval,
        probeIdleSeconds: TimeInterval
    ) -> [DurationObservation] {
        var observations: [DurationObservation] = []
        var currentDuration: TimeInterval?
        var currentStartedAt: Date?
        var canReconstructFromIdleCounter = false
        var previous: ObservationRecord?
        var recordedProbe = probeIdleSeconds

        func finish(censored: Bool) {
            if let duration = currentDuration, duration >= 1 {
                observations.append(DurationObservation(
                    duration: duration,
                    isRightCensored: censored
                ))
            }
            currentDuration = nil
            currentStartedAt = nil
        }

        for record in records {
            if let configuration = record.replayTick?.configuration {
                recordedProbe = configuration.probeIdleSeconds
            }
            if let previous {
                let gap = record.timestamp.timeIntervalSince(previous.timestamp)
                if gap < 0 || gap > maximumGap {
                    finish(censored: true)
                    canReconstructFromIdleCounter = false
                } else if record.idleSeconds + maximumGap < previous.idleSeconds {
                    // The idle counter falling substantially is proof of input even if the
                    // one-second app timer missed the instant at which it happened.
                    finish(censored: false)
                    canReconstructFromIdleCounter = true
                }
            }

            if record.event == "episodeBoundary" || record.event == "sessionBoundary" {
                finish(censored: true)
                canReconstructFromIdleCounter = false
                previous = record
                continue
            }
            if record.event == "idleStarted" || record.event == "idleUnanchored" {
                finish(censored: true)
                canReconstructFromIdleCounter = record.event == "idleStarted"
            }

            if record.event == "inputResumed"
                || record.event == "inputAnchor"
                || record.idleSeconds < 1 {
                finish(censored: false)
                canReconstructFromIdleCounter = true
                previous = record
                continue
            }

            switch record.observation {
            case .present:
                if currentStartedAt == nil {
                    currentStartedAt = record.timestamp
                    currentDuration = canReconstructFromIdleCounter ? record.idleSeconds : 0
                } else if canReconstructFromIdleCounter {
                    currentDuration = max(currentDuration ?? 0, record.idleSeconds)
                } else if let start = currentStartedAt {
                    currentDuration = max(
                        currentDuration ?? 0,
                        record.timestamp.timeIntervalSince(start)
                    )
                }
            case .absent:
                // Presence ended while input was still idle. A later return without input is
                // a new spell and cannot inherit the old idle counter as its duration.
                finish(censored: false)
                canReconstructFromIdleCounter = false
            case .unknown:
                // Unknown before the configured probe is expected because the camera is off.
                // Once sensing should be active, it cannot support continuous presence.
                if record.idleSeconds >= recordedProbe {
                    if currentDuration != nil {
                        finish(censored: true)
                    }
                    canReconstructFromIdleCounter = false
                }
            }
            previous = record
        }

        finish(censored: true)
        return observations
    }

    private static func censoredDurationSummary(
        _ observations: [DurationObservation]
    ) -> DurationSummary {
        let usable = observations.filter { $0.duration > 0 && $0.duration.isFinite }
            .sorted { $0.duration < $1.duration }
        var quantiles: [TimeInterval] = []
        let probabilities = [0.50, 0.90, 0.95, 0.99]
        var survival = 1.0
        var index = 0
        // At a shared duration, apply every observed ending before removing the censored
        // spells from the risk set. A single pass supplies all four report quantiles.
        while index < usable.count && quantiles.count < probabilities.count {
            let time = usable[index].duration
            let atRisk = usable.count - index
            var completed = 0
            repeat {
                if !usable[index].isRightCensored { completed += 1 }
                index += 1
            } while index < usable.count && usable[index].duration == time
            survival *= 1 - Double(completed) / Double(atRisk)
            while quantiles.count < probabilities.count && 1 - survival + 1e-12 >= probabilities[quantiles.count] {
                quantiles.append(time)
            }
        }

        func quantile(_ index: Int) -> TimeInterval? {
            quantiles.indices.contains(index) ? quantiles[index] : nil
        }
        return DurationSummary(
            count: usable.count,
            rightCensoredCount: usable.filter(\.isRightCensored).count,
            median: quantile(0),
            p90: quantile(1),
            p95: quantile(2),
            p99: quantile(3),
            maximum: usable.last?.duration
        )
    }

    private static func durationSummary(
        _ values: [TimeInterval],
        rightCensoredCount: Int
    ) -> DurationSummary {
        DurationSummary(
            count: values.count,
            rightCensoredCount: rightCensoredCount,
            median: percentile(values, probability: 0.50),
            p90: percentile(values, probability: 0.90),
            p95: percentile(values, probability: 0.95),
            p99: percentile(values, probability: 0.99),
            maximum: values.max()
        )
    }
}
