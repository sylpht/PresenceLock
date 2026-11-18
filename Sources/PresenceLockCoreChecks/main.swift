import Foundation
import PresenceLockCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case let .failed(message): return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else { throw CheckFailure.failed(message) }
}

let configuration = DetectionConfiguration(
    probeIdleSeconds: 5,
    absenceConfirmationSeconds: 10,
    warningSeconds: 5,
    maximumSampleAgeSeconds: 2,
    sampleIntervalSeconds: 1
)

func input(
    at date: Date,
    idle: TimeInterval,
    observation: PresenceObservation,
    cameraAvailable: Bool = true,
    capturedAt: Date? = nil,
    cameraEvidence: CameraTickEvidence = .none
) -> StateMachineInput {
    let captureTime = capturedAt ?? date
    return StateMachineInput(
        now: date,
        monotonicNow: date.timeIntervalSince1970,
        idleSeconds: idle,
        reading: PresenceReading(
            observation: observation,
            confidence: observation == .unknown ? 0 : 0.9,
            capturedAt: captureTime,
            capturedAtMonotonic: captureTime.timeIntervalSince1970,
            cameraAvailable: cameraAvailable
        ),
        cameraEvidence: cameraEvidence
    )
}

func record(
    at date: Date,
    idle: TimeInterval,
    observation: PresenceObservation,
    readingAgeSeconds: TimeInterval? = nil,
    event: String? = nil
) -> ObservationRecord {
    ObservationRecord(
        timestamp: date,
        idleSeconds: idle,
        observation: observation,
        confidence: observation == .unknown ? 0 : 0.8,
        cameraAvailable: observation != .unknown,
        readingAgeSeconds: readingAgeSeconds,
        state: .presentQuiet,
        mode: .learning,
        event: event
    )
}

func checkCompletedPresenceEpisodes() throws {
    let origin = Date(timeIntervalSince1970: 21_000)
    let completed = ObservationRecord(
        timestamp: origin.addingTimeInterval(61), idleSeconds: 60, observation: .unknown,
        confidence: 0, cameraAvailable: false, state: .active, mode: .learning, event: "inputResumed"
    )
    let interrupted = ObservationRecord(
        timestamp: origin.addingTimeInterval(260), idleSeconds: 160, observation: .unknown,
        confidence: 0, cameraAvailable: false, state: .active, mode: .learning, event: "inputResumed"
    )
    let partial = record(
        at: origin.addingTimeInterval(170), idle: 75, observation: .present, event: "episodeBoundary"
    )
    let corrected = ObservationRecord(
        timestamp: origin.addingTimeInterval(470), idleSeconds: 120, observation: .unknown,
        confidence: 0, cameraAvailable: false, state: .active, mode: .learning, event: "inputResumed"
    )
    let cameraRecords = stride(from: 8, through: 60, by: 2).map { second in
        record(at: origin.addingTimeInterval(Double(second)), idle: Double(second),
               observation: second == 8 ? .unknown : .present)
    }
    let labelsAt = origin.addingTimeInterval(600)
    let summary = StatisticsEngine.summarize(
        records: cameraRecords + [completed, partial, interrupted, corrected],
        episodeFeedback: [
            .init(episodeID: completed.id, timestamp: labelsAt, label: .stayedPresent),
            .init(episodeID: partial.id, timestamp: labelsAt, label: .stayedPresent),
            .init(episodeID: interrupted.id, timestamp: labelsAt, label: .stayedPresent),
            .init(episodeID: corrected.id, timestamp: labelsAt, label: .stayedPresent),
            .init(episodeID: corrected.id, timestamp: labelsAt, label: .departed)
        ]
    )
    try expect(summary.confirmedPresentIdleEpisodes.count == 1, "partial, interrupted, or corrected marks were accepted")
    try expect(summary.confirmedPresentIdleEpisodes.maximum == 60, "manual episode lost time before the camera started")
    try expect(summary.presentIdleRuns.maximum == 50, "camera observations did not remain a separate time estimate")
}

func checkDecisionReplayAfterTyping() throws {
    let origin = Date(timeIntervalSince1970: 22_000)
    let baseline = DetectionConfiguration.learningDefault
    let machine = PresenceStateMachine(configuration: baseline)
    var records: [ObservationRecord] = []
    for second in 0...74 {
        let time = Double(second)
        let date = origin.addingTimeInterval(time)
        let typing = second < 30 || second == 74
        let idle = typing ? 0.2 : time - 29
        let observation: PresenceObservation = idle >= baseline.probeIdleSeconds ? .absent : .unknown
        let sample = input(at: date, idle: idle, observation: observation, cameraAvailable: !typing)
        let actions = machine.update(sample)
        guard second == 0 || second >= 30 else { continue }

        let event: String?
        if second == 0 { event = "inputAnchor" }
        else if second == 30 { event = "idleStarted" }
        else if second == 74 { event = "inputResumed" }
        else if actions.contains(.warningStarted) { event = "warningStarted" }
        else if actions.contains(.wouldLock) { event = "wouldLock" }
        else { event = nil }
        records.append(ObservationRecord(
            timestamp: date,
            idleSeconds: second == 74 ? 44 : idle,
            observation: observation,
            confidence: sample.reading.confidence,
            cameraAvailable: sample.reading.cameraAvailable,
            readingAgeSeconds: 0,
            state: machine.state,
            mode: .learning,
            event: event,
            replayTick: DecisionReplayTick(
                monotonicTime: sample.monotonicNow,
                updateGapSeconds: second == 0 ? 0 : 1,
                idleSeconds: idle,
                inputOccurred: false,
                configuration: second == 30 ? baseline : nil
            )
        ))
    }
    let verification = ThresholdReplay.verifyReferenceDecisions(records: records)
    try expect(verification.checkedEpisodes == 1 && verification.matchingEpisodes == 1,
               "decision replay lost the input anchor after continuous typing")
    try expect(verification.recordedPredictions == 1 && verification.replayedPredictions == 1,
               "same-threshold replay did not reproduce the live prediction")

    guard let prediction = records.first(where: { $0.event == "wouldLock" }) else {
        throw CheckFailure.failed("the reference fixture has no prediction to label")
    }
    let candidates = [
        ThresholdCandidate(probeIdleSeconds: 8, absenceConfirmationSeconds: 20),
        ThresholdCandidate(probeIdleSeconds: 8, absenceConfirmationSeconds: 45)
    ]
    let comparison = ThresholdReplay.evaluate(
        records: records,
        feedback: [.init(predictionID: prediction.id, label: .confirmedDeparture)],
        candidates: candidates,
        includeLegacy: false
    )
    try expect(comparison.map(\.confirmedDepartures) == [1, 1], "candidates used different evaluation cohorts")
    try expect(comparison.map(\.confirmedDeparturesCaught) == [1, 0],
               "the threshold comparison did not distinguish a caught departure from a miss")

    let previewRecords = records.map { original in
        guard original.event == "idleStarted", let tick = original.replayTick else { return original }
        var record = original
        record.replayTick = DecisionReplayTick(
            monotonicTime: tick.monotonicTime,
            updateGapSeconds: tick.updateGapSeconds,
            idleSeconds: tick.idleSeconds,
            inputOccurred: tick.inputOccurred,
            configuration: tick.configuration,
            cameraPreviewActive: true
        )
        return record
    }
    let previewComparison = ThresholdReplay.evaluate(
        records: previewRecords,
        feedback: [.init(predictionID: prediction.id, label: .confirmedDeparture)],
        candidates: candidates,
        includeLegacy: false
    )
    try expect(previewComparison.map(\.excludedEpisodes) == [1, 1]
                && previewComparison.allSatisfy { $0.eligibleEpisodes == 0 },
               "a preview that closed before the normal probe leaked into threshold comparison")
    try expect(ThresholdReplay.verifyReferenceDecisions(records: previewRecords) == verification,
               "preview metadata changed the verification of decisions actually recorded")

    let missingTick = records.filter { $0.replayTick?.idleSeconds != 19 }
    let incomplete = ThresholdReplay.verifyReferenceDecisions(records: missingTick)
    try expect(incomplete.checkedEpisodes == 0 && incomplete.incompleteTraces == 1,
               "a missing decision tick was silently treated as a complete recording")
}

func checkFreshConfirmationAfterWarning() throws {
    let origin = Date(timeIntervalSince1970: 23_000)

    func tick(
        _ second: TimeInterval,
        capturedAt captureSecond: TimeInterval? = nil,
        evidence: CameraTickEvidence = .none
    ) -> StateMachineInput {
        input(
            at: origin.addingTimeInterval(second),
            idle: second,
            observation: .absent,
            capturedAt: captureSecond.map { origin.addingTimeInterval($0) },
            cameraEvidence: evidence
        )
    }

    func machineAtWarning(mode: MonitoringMode) throws -> PresenceStateMachine {
        let machine = PresenceStateMachine(mode: mode, configuration: configuration)
        _ = machine.update(input(at: origin, idle: 0, observation: .present))
        _ = machine.update(tick(6))
        try expect(machine.update(tick(16)).contains(.warningStarted), "test could not start warning")
        return machine
    }

    for evidence in [
        CameraTickEvidence(sawPresence: true),
        CameraTickEvidence(sawUncertainty: true)
    ] {
        let machine = try machineAtWarning(mode: .armed)
        // The camera saw presence or uncertainty in between polls, but the last frame is absent.
        let actions = machine.update(tick(21, evidence: evidence))
        try expect(actions.contains(.warningCancelled), "intermediate camera evidence was lost at the deadline")
        try expect(!actions.contains(.lock), "intermediate camera evidence allowed a lock")
        try expect(machine.warningRemainingSeconds(atMonotonic: origin.timeIntervalSince1970 + 21) == nil,
                   "cancelled warning left an active countdown")
        let subsequent = machine.update(tick(22))
        try expect(!subsequent.contains(.lock) && !subsequent.contains(.warningStarted),
                   "warning resumed instead of restarting absence confirmation")
    }

    for mode in [MonitoringMode.learning, .armed] {
        let machine = try machineAtWarning(mode: mode)
        let decision = mode.performsRealLock ? StateMachineAction.lock : .wouldLock
        let atDeadline = machine.update(tick(21, capturedAt: 20.75))
        try expect(!atDeadline.contains(decision), "a pre-deadline frame confirmed the lock")
        try expect(machine.warningRemainingSeconds(atMonotonic: origin.timeIntervalSince1970 + 21) == 0,
                   "warning did not wait for final camera confirmation")
        let fresh = machine.update(tick(22, capturedAt: 21.5))
        try expect(fresh.contains(decision), "a fresh post-deadline absent frame did not confirm the lock")
    }

    let staleMachine = try machineAtWarning(mode: .armed)
    _ = staleMachine.update(tick(21, capturedAt: 20.75))
    let stale = staleMachine.update(tick(24, capturedAt: 21.5))
    try expect(stale.contains(.warningCancelled) && !stale.contains(.lock),
               "a post-deadline frame that had become stale confirmed the lock")
}

func checkReplayOfWarningEvidence() throws {
    let replayConfiguration = DetectionConfiguration(
        probeIdleSeconds: 5,
        absenceConfirmationSeconds: 1,
        warningSeconds: 1,
        maximumSampleAgeSeconds: 2,
        sampleIntervalSeconds: 1
    )

    func makeTrace(modern: Bool, epoch: TimeInterval) -> [ObservationRecord] {
        let origin = Date(timeIntervalSince1970: epoch)
        let machine = PresenceStateMachine(configuration: replayConfiguration, requirePostWarningFrame: modern)
        return (0...12).map { second in
            let time = Double(second)
            let date = origin.addingTimeInterval(time)
            let isInput = second == 0 || second == 12
            let idle = isInput ? 0 : time
            let observation: PresenceObservation = isInput || second < 5 ? .unknown : .absent
            let captureOffset = [7, 10, 11].contains(second) ? 0.25 : 0
            let evidence = CameraTickEvidence(sawPresence: modern && second == 7)
            var sample = input(
                at: date, idle: idle, observation: observation, cameraAvailable: observation == .absent,
                capturedAt: date.addingTimeInterval(-captureOffset), cameraEvidence: evidence
            )
            sample.inputOccurred = isInput
            let actions = machine.update(sample)
            let event: String?
            if second == 0 { event = "inputAnchor" }
            else if second == 1 { event = "idleStarted" }
            else if second == 12 { event = "inputResumed" }
            else if actions.contains(.warningStarted) { event = "warningStarted" }
            else if actions.contains(.warningCancelled) { event = "warningCancelled" }
            else if actions.contains(.wouldLock) { event = "wouldLock" }
            else { event = nil }
            return ObservationRecord(
                timestamp: date,
                idleSeconds: second == 12 ? 11 : idle,
                observation: observation,
                confidence: sample.reading.confidence,
                cameraAvailable: sample.reading.cameraAvailable,
                readingAgeSeconds: captureOffset,
                state: machine.state,
                mode: .learning,
                event: event,
                replayTick: DecisionReplayTick(
                    monotonicTime: sample.monotonicNow,
                    updateGapSeconds: second == 0 ? 0 : 1,
                    idleSeconds: idle,
                    inputOccurred: isInput,
                    configuration: second == 1 ? replayConfiguration : nil,
                    cameraEvidence: modern ? evidence : nil
                )
            )
        }
    }

    let archived = makeTrace(modern: false, epoch: 24_000)
    let current = makeTrace(modern: true, epoch: 25_000)
    try expect(archived.filter { $0.event == "wouldLock" }.map(\.idleSeconds) == [7],
               "legacy rules did not reproduce the historical warning deadline")
    try expect(current.filter { $0.event == "wouldLock" }.map(\.idleSeconds) == [11],
               "new rules did not respect intermediate presence and the fresh final frame")

    let verification = ThresholdReplay.verifyReferenceDecisions(records: archived + current)
    try expect(verification.checkedEpisodes == 2 && verification.matchingEpisodes == 2,
               "replay did not preserve the decisions of both recording formats")
    try expect(verification.recordedPredictions == 2 && verification.replayedPredictions == 2,
               "replay dropped a decision when switching recording formats")
}

func checkRearmingAfterDeparture() throws {
    let origin = Date(timeIntervalSince1970: 28_000)
    for mode in MonitoringMode.allCases {
        for returnByInput in [false, true] {
            let machine = PresenceStateMachine(mode: mode)
            var warnings: [Int] = []
            var decisions: [Int] = []
            for second in 0...111 {
                let time = origin.addingTimeInterval(Double(second))
                let idle = returnByInput && second >= 70 ? second - 70 : second
                var tick = input(at: time, idle: Double(idle), observation: second == 34 ? .unknown : .absent)
                if second == 70 {
                    tick.inputOccurred = returnByInput
                    tick.cameraEvidence.sawPresence = !returnByInput
                }
                let actions = machine.update(tick)
                if actions.contains(.warningStarted) { warnings.append(second) }
                if actions.contains(mode.performsRealLock ? .lock : .wouldLock) { decisions.append(second) }
                if second == 35 {
                    try expect(machine.state == .triggered && machine.warningDeadlineMonotonic == nil,
                               "an empty frame after uncertainty restarted the handled departure")
                }
            }
            try expect(warnings == [28, returnByInput ? 98 : 91],
                       "duplicate or missing countdown after a single departure and return")
            try expect(decisions == [33, returnByInput ? 103 : 96],
                       "unexpected decision before or after rearming")
        }
    }

    // Model a 0.2.5/0.2.6 journal in which a second warning at 55 finished silently.
    let archived: [ObservationRecord] = (1...63).map { second in
        let end = second == 63
        let idle = Double(second)
        let time = origin.addingTimeInterval(idle)
        var row = record(at: time, idle: end ? 62 : idle,
                         observation: second == 34 || second < 8 || end ? .unknown : .absent,
                         readingAgeSeconds: 0)
        row.replayTick = DecisionReplayTick(
            monotonicTime: time.timeIntervalSince1970, updateGapSeconds: 1,
            idleSeconds: end ? 0 : idle, inputOccurred: end,
            configuration: second == 1 ? .learningDefault : nil, cameraEvidence: CameraTickEvidence()
        )
        switch second {
        case 1: row.event = "idleStarted"
        case 28, 55: row.event = "warningStarted"
        case 33: row.event = "wouldLock"
        case 63: row.event = "inputResumed"
        default: break
        }
        switch second {
        case 1..<8: row.state = .quiet
        case 8..<28, 35..<55: row.state = .suspectedAway
        case 28..<33, 55..<60: row.state = .warning
        case 33, 60..<63: row.state = .triggered
        case 34: row.state = .unknown
        default: row.state = .active
        }
        return row
    }
    let old = ThresholdReplay.verifyReferenceDecisions(records: archived)
    try expect(old.matchingEpisodes == 1 && old.checkedEpisodes == 1
               && old.recordedPredictions == 1 && old.replayedPredictions == 1,
               "an archived duplicate warning changed the forecast in replay")
}

func checkPassiveEpisodes() throws {
    func trace(
        epoch: TimeInterval = 30_000,
        configuration: DetectionConfiguration = .learningDefault,
        previewAt: Int? = nil,
        freezeAt: Int? = nil,
        observationAt: (Int) -> PresenceObservation
    ) -> [ObservationRecord] {
        let machine = PresenceStateMachine(configuration: configuration)
        var records: [ObservationRecord] = []
        for second in 0...61 {
            let now = Date(timeIntervalSince1970: epoch + Double(second))
            let inputReturned = second == 0 || second == 61
            let idle = inputReturned ? 0.2 : Double(second)
            let frameSecond = min(second - second % 2, freezeAt ?? second)
            let cameraReady = !inputReturned && Double(frameSecond) >= configuration.probeIdleSeconds + 2
            let observation = cameraReady ? observationAt(frameSecond) : .unknown
            let age = cameraReady ? Double(second - frameSecond) + 0.1 : 0
            let evidence = CameraTickEvidence(
                sawPresence: cameraReady && second == frameSecond && observation == .present,
                sawUncertainty: cameraReady && second == frameSecond && observation == .unknown
            )
            var sample = input(at: now, idle: idle, observation: observation, cameraAvailable: cameraReady,
                               capturedAt: now.addingTimeInterval(-age), cameraEvidence: evidence)
            sample.inputOccurred = inputReturned
            sample.updateGapSeconds = second == 0 ? 0 : 1
            let actions = machine.update(sample)
            var row = record(at: now, idle: second == 61 ? 60 : idle, observation: observation, readingAgeSeconds: age)
            row.cameraAvailable = cameraReady
            row.state = machine.state
            row.replayTick = DecisionReplayTick(
                monotonicTime: sample.monotonicNow, updateGapSeconds: sample.updateGapSeconds,
                idleSeconds: idle, inputOccurred: inputReturned,
                configuration: second == 1 ? configuration : nil,
                cameraPreviewActive: second == previewAt ? true : nil, cameraEvidence: evidence
            )
            // Real journals put the tick on the first event and log secondary actions after it.
            var events: [String] = []
            if second == 0 { events.append("inputAnchor") }
            if second == 1 { events.append("idleStarted") }
            if second == 61 { events.append("inputResumed") }
            if actions.contains(.warningStarted) { events.append("warningStarted") }
            if actions.contains(.warningCancelled) { events.append("warningCancelled") }
            if actions.contains(.wouldLock) { events.append("wouldLock") }
            row.event = events.first
            records.append(row)
            for event in events.dropFirst() {
                row.id = UUID()
                row.event = event
                row.replayTick = nil
                row.idleSeconds = idle
                records.append(row)
            }
        }
        return records
    }

    let present = trace(configuration: DetectionConfiguration(probeIdleSeconds: 18)) { _ in .present }
    let away = trace(epoch: 31_000) { second in (16...49).contains(second) ? .absent : .present }
    let unfocused = trace(epoch: 32_000) { second in second % 4 == 0 ? .absent : .unknown }
    let empty = trace(epoch: 33_000) { _ in .absent }
    let onReturn = trace(epoch: 34_000) { second in second < 38 ? .present : .absent }
    let records = empty + unfocused + present + away + onReturn
    let summary = PassiveEpisodeAnalysis.summarize(records: records)
    try expect(summary.likelyPresent == 1 && summary.likelyAway == 3 && summary.uncertain == 1,
               "independent camera estimates did not classify sustained and ambiguous evidence correctly")
    try expect(summary.presentIdleMedian == 60 && summary.presentIdleP90 == 60 && summary.presentIdleMaximum == 60,
               "a passive pause used the post-input idle value or omitted the custom camera warm-up")
    try expect(onReturn.suffix(2).map(\.event) == ["inputResumed", "warningCancelled"],
               "the fixture no longer models a warning cancellation in a secondary journal row")

    guard let episodeID = present.last?.id else { throw CheckFailure.failed("missing inputResumed ID") }
    let marked = PassiveEpisodeAnalysis.summarize(
        records: records, episodeFeedback: [.init(episodeID: episodeID, label: .departed)]
    )
    try expect(marked.likelyPresent == 0 && marked.presentIdleMaximum == nil && marked.likelyAway == 3,
               "a manually corrected episode remained in the sensor-only evidence")
    guard let prediction = empty.first(where: { $0.event == "wouldLock" }) else {
        throw CheckFailure.failed("missing predicted lock in the empty-camera trace")
    }
    let rejected = PassiveEpisodeAnalysis.summarize(
        records: empty, predictionFeedback: [.init(predictionID: prediction.id, label: .falseAlarm)]
    )
    try expect(rejected.likelyAway == 0 && rejected.uncertain == 0,
               "a human-reported false alarm was still counted as a passive departure")
    let accuracy = StatisticsEngine.summarize(records: records)
    try expect(accuracy.predictedLocks > 0 && accuracy.confirmedDepartures == 0 && accuracy.falseAlarms == 0
               && accuracy.confirmedPresentIdleEpisodes.count == 0,
               "a passive estimate was reported as independent confirmation")

    let stale = trace(freezeAt: 10) { _ in .present }
    let oneFrame = PassiveEpisodeAnalysis.summarize(records: stale)
    try expect(oneFrame.uncertain == 1 && oneFrame.likelyPresent == 0,
               "polls of one old frame were accepted as continuous camera coverage")

    let dark = trace { _ in .unknown }
    let noImage = PassiveEpisodeAnalysis.summarize(records: dark)
    try expect(noImage.uncertain == 1 && noImage.likelyAway == 0,
               "unknown frames were interpreted as an empty desk")

    var unanchored = present
    unanchored[1].event = "idleUnanchored"
    var interrupted = present
    interrupted[30].event = "sessionBoundary"
    var legacy = present
    for index in legacy.indices { legacy[index].replayTick = nil }
    let preview = trace(previewAt: 27) { _ in .present }
    let previewAway = trace(previewAt: 37) { _ in .absent }
    let previewStatistics = StatisticsEngine.summarize(records: preview + previewAway.map { record in
        var later = record
        later.timestamp = later.timestamp.addingTimeInterval(200)
        return later
    })
    try expect(previewStatistics.presentIdleRuns.count == 0 && previewStatistics.absenceRuns.count == 0,
               "camera timing summaries counted part of a preview-contaminated pause")
    let frozenEmpty = trace(freezeAt: 10) { _ in .absent }
    try expect(StatisticsEngine.summarize(records: frozenEmpty).absenceRuns.count == 0,
               "an old camera frame counted as multiple observations of absence")
    var missedInput = present
    let index = missedInput.firstIndex { $0.replayTick?.idleSeconds == 30 }!
    let original = missedInput[index].replayTick!
    missedInput[index].replayTick = DecisionReplayTick(
        monotonicTime: original.monotonicTime, updateGapSeconds: original.updateGapSeconds,
        idleSeconds: original.idleSeconds - 1, inputOccurred: false, cameraEvidence: original.cameraEvidence
    )
    let missingTick = present.filter { $0.replayTick?.idleSeconds != 35 }
    for excluded in [unanchored, interrupted, legacy, preview, missingTick, missedInput, Array(present.dropLast())] {
        let result = PassiveEpisodeAnalysis.summarize(records: excluded)
        try expect(result.likelyPresent == 0 && result.likelyAway == 0 && result.uncertain == 0,
                   "preview, incomplete, interrupted or historical evidence entered the passive cohort")
    }
}

func checkPoseShadow() throws {
    let epoch = 60_000.0
    let config = DetectionConfiguration.learningDefault
    func trace(
        samples: [Int: PoseShadowSample],
        end: Int = 39,
        previewAt: Int? = nil,
        mode: MonitoringMode = .learning,
        presenceAt: Int? = nil
    ) -> [ObservationRecord] {
        let machine = PresenceStateMachine(mode: mode, configuration: config)
        var rows: [ObservationRecord] = []
        for second in 0...end {
            let date = Date(timeIntervalSince1970: epoch + Double(second))
            let returned = second == 0 || second == end
            let idle = returned ? 0.0 : Double(second)
            let cameraOn = idle >= config.probeIdleSeconds
            let observation: PresenceObservation = !cameraOn ? .unknown : second == presenceAt ? .present : .absent
            var sample = input(at: date, idle: idle, observation: observation, cameraAvailable: cameraOn)
            sample.inputOccurred = returned
            sample.updateGapSeconds = second == 0 ? 0 : 1
            let actions = machine.update(sample)
            let tick = DecisionReplayTick(
                monotonicTime: sample.monotonicNow, updateGapSeconds: sample.updateGapSeconds,
                idleSeconds: idle, inputOccurred: returned, configuration: second == 1 ? config : nil,
                cameraPreviewActive: second == previewAt ? true : nil, cameraEvidence: CameraTickEvidence.none,
                poseShadow: samples[second]
            )
            var row = record(at: date, idle: second == end ? Double(end - 1) : idle, observation: observation,
                             readingAgeSeconds: 0)
            row.cameraAvailable = cameraOn
            row.mode = mode
            row.state = machine.state
            row.replayTick = tick
            if second == 0 { row.event = "inputAnchor" }
            if second == 1 { row.event = "idleStarted" }
            if second == end { row.event = "inputResumed" }
            rows.append(row)
            for (action, event) in [(StateMachineAction.warningStarted, "warningStarted"), (.wouldLock, "wouldLock")] {
                if actions.contains(action) {
                    var companion = row
                    companion.id = UUID()
                    companion.replayTick = nil
                    companion.event = event
                    rows.append(companion)
                }
            }
        }
        return rows
    }

    func frame(_ second: Double, _ result: PoseShadowResult = .torsoDetected) -> PoseShadowSample {
        PoseShadowSample(capturedAtMonotonic: epoch + second - 0.1, result: result)
    }
    let strong = [24: frame(24), 26: frame(26), 28: frame(28), 32: frame(32)]
    let withPose = trace(samples: strong)
    let legacy = trace(samples: [:])
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("presence-pose-check-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try JSONLEventStore(directoryURL: directory)
    for row in withPose { try store.append(row) }
    let stored = try store.loadObservationRecords()
    try expect(stored == withPose, "pose metadata did not survive journal readback and same-second event ordering")
    guard let oldTick = legacy.first?.replayTick else { throw CheckFailure.failed("fixture lost its old tick") }
    let oldData = try JSONEncoder().encode(oldTick)
    let oldJSON = try JSONSerialization.jsonObject(with: oldData) as? [String: Any]
    let decodedOld = try JSONDecoder().decode(DecisionReplayTick.self, from: oldData)
    try expect(oldJSON?["poseShadow"] == nil && decodedOld.poseShadow == nil, "legacy absent pose field requires migration")

    let summary = PoseShadowAnalysis.summarize(records: stored)
    try expect(summary.sampledEpisodes == 1 && summary.torsoFrames == 4 && summary.corroboratedEpisodes == 1,
               "distinct positive torso frames were not associated within one ordinary episode")
    try expect(summary.warningsWithSupport == 1 && summary.predictionsWithSupport == 1,
               "adjacent decision rows did not inherit the evidence available on their actual decision tick")
    let comparison = ThresholdReplay.comparePoseShadow(records: stored, summary: summary)
    try expect(comparison.episodes == 1 && comparison.baselineWarnings == 1 && comparison.baselinePredictions == 1
               && comparison.candidateWarnings == 0 && comparison.candidatePredictions == 0
               && comparison.medianFirstPredictionDelay == nil, "paired pose replay did not isolate the candidate veto")
    let parity = ThresholdReplay.verifyReferenceDecisions(records: stored)
    try expect(parity.checkedEpisodes == 1 && parity.matchingEpisodes == 1 && parity.recordedPredictions == 1
               && parity == ThresholdReplay.verifyReferenceDecisions(records: legacy),
               "shadow pose changed the actual baseline decision")
    let human = StatisticsEngine.summarize(records: stored)
    try expect(human.confirmedDepartures == 0 && human.falseAlarms == 0 && human.confirmedPresentIdleEpisodes.count == 0,
               "shadow model output was counted as a human label")

    let delayed = trace(samples: [24: frame(24), 26: frame(26)], end: 60)
    let both = ThresholdReplay.comparePoseShadow(records: delayed, summary: PoseShadowAnalysis.summarize(records: delayed))
    try expect(both.baselinePredictions == 1 && both.candidatePredictions == 1
               && (both.medianFirstPredictionDelay ?? 0) > 0,
               "a delayed candidate counted as an averted baseline prediction")
    for samples in [
        [28: frame(28)], [27: frame(27), 28: frame(27)], [22: frame(22), 28: frame(28)],
        [26: frame(26), 27: frame(27, .noReliableTorso), 28: frame(28)],
        [26: frame(26), 27: frame(27, .unavailable), 28: frame(28)],
        [26: frame(26), 28: frame(21)]
    ] {
        let weak = PoseShadowAnalysis.summarize(records: trace(samples: samples))
        try expect(weak.corroboratedEpisodes == 0 && weak.warningsWithSupport == 0,
                   "isolated, repeated, stale or interrupted pose readings corroborated each other")
    }
    let restored = PoseShadowAnalysis.summarize(records: trace(samples: [26: frame(26), 28: frame(28)], presenceAt: 27))
    try expect(restored.corroboratedEpisodes == 0, "pose readings were joined across a real return")
    var boundary = withPose
    boundary[boundary.count - 1].event = "episodeBoundary"
    var mixed = withPose
    mixed[17].mode = .armed
    for excluded in [legacy, trace(samples: strong, previewAt: 3), trace(samples: strong, mode: .armed),
                     boundary, mixed, Array(withPose.dropLast())] {
        let skipped = PoseShadowAnalysis.summarize(records: excluded)
        let pair = ThresholdReplay.comparePoseShadow(records: excluded, summary: skipped)
        try expect(skipped.sampledEpisodes == 0 && pair.episodes == 0,
                   "ineligible episode entered the pose analysis")
    }
}

func runChecks() throws {
    try checkCompletedPresenceEpisodes()
    try checkDecisionReplayAfterTyping()
    try checkFreshConfirmationAfterWarning()
    try checkReplayOfWarningEvidence()
    try checkRearmingAfterDeparture()
    try checkPassiveEpisodes()
    try checkPoseShadow()
    do {
        let invalid = DetectionConfiguration(
            probeIdleSeconds: .nan,
            absenceConfirmationSeconds: .infinity,
            warningSeconds: -4,
            maximumSampleAgeSeconds: 0,
            maximumUpdateGapSeconds: 0,
            sampleIntervalSeconds: 0
        )
        try expect(invalid.probeIdleSeconds == 8, "non-finite probe did not use its safe fallback")
        try expect(
            invalid.absenceConfirmationSeconds == 20,
            "non-finite absence confirmation did not use its safe fallback"
        )
        try expect(invalid.warningSeconds == 1, "warning minimum was not enforced")
        try expect(invalid.maximumSampleAgeSeconds == 0.25, "sample-age minimum was not enforced")
        try expect(invalid.maximumUpdateGapSeconds == 1, "update-gap minimum was not enforced")
        try expect(invalid.sampleIntervalSeconds == 0.25, "sample interval minimum was not enforced")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 1_000)
        for offset in stride(from: 0.0, through: 30.0, by: 5.0) {
            let now = start.addingTimeInterval(offset)
            let actions = machine.update(input(at: now, idle: 30 + offset, observation: .absent))
            try expect(!actions.contains(.lock), "launch guard allowed a lock")
        }
        try expect(machine.state == .launchGuard, "launch guard state was lost")
    }

    do {
        let machine = PresenceStateMachine(mode: .learning, configuration: configuration)
        let start = Date(timeIntervalSince1970: 2_000)
        _ = machine.update(input(at: start, idle: 0, observation: .unknown, cameraAvailable: false))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(16), idle: 16, observation: .absent))
        let early = machine.update(input(at: start.addingTimeInterval(20), idle: 20, observation: .absent))
        try expect(!early.contains(.wouldLock), "prediction fired before warning ended")
        let final = machine.update(input(at: start.addingTimeInterval(21), idle: 21, observation: .absent))
        try expect(final.contains(.wouldLock), "learning prediction did not fire")
        try expect(!final.contains(.lock), "learning mode performed a real lock")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 2_500)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        let warning = machine.update(input(
            at: start.addingTimeInterval(16),
            idle: 16,
            observation: .absent
        ))
        try expect(warning.contains(.warningStarted), "warning did not start after confirmed absence")
        try expect(
            machine.warningRemainingSeconds(atMonotonic: start.timeIntervalSince1970 + 16) == 5,
            "warning countdown did not start at the configured duration"
        )
        try expect(
            machine.warningRemainingSeconds(atMonotonic: start.timeIntervalSince1970 + 18.25) == 2.75,
            "warning countdown did not use the monotonic clock"
        )
        let acknowledged = machine.acknowledgePresence()
        try expect(acknowledged.contains(.warningCancelled), "warning acknowledgement was not recorded")
        try expect(machine.state == .active, "warning acknowledgement did not restore active state")
        try expect(
            machine.warningRemainingSeconds(atMonotonic: start.timeIntervalSince1970 + 19) == nil,
            "warning countdown survived acknowledgement"
        )
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 2_700)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(16), idle: 16, observation: .absent))
        let first = machine.update(input(at: start.addingTimeInterval(21), idle: 21, observation: .absent))
        let repeated = machine.update(input(at: start.addingTimeInterval(22), idle: 22, observation: .absent))
        let repeatedAgain = machine.update(input(at: start.addingTimeInterval(30), idle: 30, observation: .absent))
        try expect(first.filter { $0 == .lock }.count == 1, "armed episode did not emit exactly one lock")
        try expect(!repeated.contains(.lock), "armed episode emitted a repeated lock")
        try expect(!repeatedAgain.contains(.lock), "triggered episode re-locked without renewed presence")

        _ = machine.update(input(at: start.addingTimeInterval(31), idle: 31, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(37), idle: 37, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(47), idle: 47, observation: .absent))
        let rearmed = machine.update(input(at: start.addingTimeInterval(52), idle: 52, observation: .absent))
        try expect(rearmed.contains(.lock), "confirmed presence did not rearm a new departure episode")
    }

    do {
        let machine = PresenceStateMachine(mode: .learning, configuration: configuration)
        let start = Date(timeIntervalSince1970: 2_900)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(16), idle: 16, observation: .absent))
        let modeActions = machine.setMode(.armed)
        try expect(modeActions.contains(.warningCancelled), "arming did not cancel an active warning")
        try expect(machine.state == .launchGuard, "arming inherited a partial departure decision")
        try expect(!machine.hasConfirmedPresence, "arming inherited pre-arm presence")

        for offset in [21.0, 31, 41] {
            let actions = machine.update(input(
                at: start.addingTimeInterval(offset),
                idle: offset,
                observation: .absent
            ))
            try expect(!actions.contains(.lock), "mode switch allowed a lock without fresh presence")
        }
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 3_000)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(16), idle: 16, observation: .absent))
        let actions = machine.update(input(at: start.addingTimeInterval(17), idle: 17, observation: .present))
        try expect(actions.contains(.warningCancelled), "presence did not cancel warning")
        try expect(machine.state == .presentQuiet, "state did not return to present")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 4_000)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        let actions = machine.update(input(
            at: start.addingTimeInterval(17),
            idle: 17,
            observation: .unknown,
            cameraAvailable: true
        ))
        try expect(!actions.contains(.lock), "unknown reading caused a lock")
        try expect(machine.state == .unknown, "unknown reading was not preserved")
    }

    do {
        func machineAtWarning(start: Date) -> PresenceStateMachine {
            let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
            _ = machine.update(input(at: start, idle: 0, observation: .present))
            _ = machine.update(input(
                at: start.addingTimeInterval(6),
                idle: 6,
                observation: .absent
            ))
            _ = machine.update(input(
                at: start.addingTimeInterval(16),
                idle: 16,
                observation: .absent
            ))
            return machine
        }

        let start = Date(timeIntervalSince1970: 4_500)

        let unknownMachine = machineAtWarning(start: start)
        let unknownActions = unknownMachine.update(input(
            at: start.addingTimeInterval(17),
            idle: 17,
            observation: .unknown,
            cameraAvailable: true
        ))
        try expect(unknownActions.contains(.warningCancelled), "unknown did not cancel an active warning")
        try expect(unknownMachine.state == .unknown, "unknown did not leave the warning state")

        let staleMachine = machineAtWarning(start: start)
        let staleActions = staleMachine.update(StateMachineInput(
            now: start.addingTimeInterval(17),
            monotonicNow: start.timeIntervalSince1970 + 17,
            idleSeconds: 17,
            reading: PresenceReading(
                observation: .absent,
                confidence: 1,
                capturedAt: start.addingTimeInterval(10),
                capturedAtMonotonic: start.timeIntervalSince1970 + 10,
                cameraAvailable: true
            )
        ))
        try expect(staleActions.contains(.warningCancelled), "stale sample did not cancel an active warning")
        try expect(staleMachine.state == .unknown, "stale sample did not become unknown")

        let gapMachine = machineAtWarning(start: start)
        let gapActions = gapMachine.update(StateMachineInput(
            now: start.addingTimeInterval(17),
            monotonicNow: start.timeIntervalSince1970 + 17,
            idleSeconds: 17,
            updateGapSeconds: 10,
            reading: PresenceReading.unknown(
                at: start.addingTimeInterval(17),
                monotonic: start.timeIntervalSince1970 + 17
            )
        ))
        try expect(gapActions.contains(.warningCancelled), "update gap did not cancel an active warning")
        try expect(gapMachine.state == .launchGuard, "update gap did not reset the session")

        let inactiveMachine = machineAtWarning(start: start)
        let inactiveActions = inactiveMachine.update(StateMachineInput(
            now: start.addingTimeInterval(17),
            monotonicNow: start.timeIntervalSince1970 + 17,
            idleSeconds: 17,
            reading: PresenceReading.unknown(
                at: start.addingTimeInterval(17),
                monotonic: start.timeIntervalSince1970 + 17
            ),
            sessionActive: false
        ))
        try expect(inactiveActions.contains(.warningCancelled), "session end did not cancel an active warning")
        try expect(inactiveMachine.state == .launchGuard, "session end did not restore launch guard")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 5_000)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        let staleReading = PresenceReading(
            observation: .absent,
            confidence: 0.9,
            capturedAt: start,
            capturedAtMonotonic: start.timeIntervalSince1970,
            cameraAvailable: true
        )
        let actions = machine.update(StateMachineInput(
            now: start.addingTimeInterval(30),
            monotonicNow: start.timeIntervalSince1970 + 30,
            idleSeconds: 30,
            reading: staleReading
        ))
        try expect(!actions.contains(.lock), "stale reading caused a lock")
        try expect(machine.state == .unknown, "stale reading did not become unknown")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 5_500)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        _ = machine.update(input(at: start.addingTimeInterval(6), idle: 6, observation: .absent))
        _ = machine.update(input(at: start.addingTimeInterval(16), idle: 16, observation: .absent))
        let actions = machine.update(StateMachineInput(
            now: start.addingTimeInterval(17),
            monotonicNow: start.timeIntervalSince1970 + 17,
            idleSeconds: 1.2,
            inputOccurred: true,
            reading: PresenceReading.unknown(
                at: start.addingTimeInterval(17),
                monotonic: start.timeIntervalSince1970 + 17
            )
        ))
        try expect(actions.contains(.warningCancelled), "brief input did not cancel warning")
        try expect(machine.state == .active, "brief input did not rearm the state machine")
    }

    do {
        let machine = PresenceStateMachine(mode: .armed, configuration: configuration)
        let start = Date(timeIntervalSince1970: 5_800)
        _ = machine.update(input(at: start, idle: 0, observation: .present))
        let actions = machine.update(StateMachineInput(
            now: start.addingTimeInterval(20),
            monotonicNow: start.timeIntervalSince1970 + 20,
            idleSeconds: 20,
            updateGapSeconds: 20,
            reading: PresenceReading(
                observation: .absent,
                confidence: 1,
                capturedAt: start.addingTimeInterval(20),
                capturedAtMonotonic: start.timeIntervalSince1970 + 20,
                cameraAvailable: true
            )
        ))
        try expect(!actions.contains(.lock), "long update gap caused a lock")
        try expect(machine.state == .launchGuard, "long update gap did not reset the launch guard")
    }

    try expect(
        StatisticsEngine.percentile([10, 20, 30, 40], probability: 0.5) == 25,
        "percentile interpolation is wrong"
    )

    do {
        let start = Date(timeIntervalSince1970: 10_000)
        let records = [
            record(
                at: start.addingTimeInterval(-5),
                idle: 0,
                observation: .unknown,
                event: "inputAnchor"
            ),
            record(at: start, idle: 5, observation: .present),
            record(at: start.addingTimeInterval(2), idle: 7, observation: .present),
            record(at: start.addingTimeInterval(4), idle: 9, observation: .present),
            record(at: start.addingTimeInterval(6), idle: 11, observation: .absent),
            record(at: start.addingTimeInterval(8), idle: 13, observation: .absent),
            record(at: start.addingTimeInterval(10), idle: 0, observation: .unknown, event: "wouldLock")
        ]
        let summary = StatisticsEngine.summarize(records: records)
        try expect(summary.presentIdleRuns.maximum == 9, "full input-idle duration was not reconstructed")
        try expect(summary.absenceRuns.maximum == 2, "absence run aggregation is wrong")
        try expect(summary.predictedLocks == 1, "prediction count is wrong")
    }

    do {
        let start = Date(timeIntervalSince1970: 12_000)
        let records = [
            record(
                at: start.addingTimeInterval(-5),
                idle: 0,
                observation: .unknown,
                event: "inputAnchor"
            ),
            record(at: start, idle: 5, observation: .present),
            record(
                at: start.addingTimeInterval(1),
                idle: 5,
                observation: .unknown,
                event: "inputResumed"
            ),
            record(at: start.addingTimeInterval(10), idle: 10, observation: .present)
        ]
        let summary = StatisticsEngine.summarize(records: records, maximumGap: 20)
        try expect(summary.presentIdleRuns.count == 2, "present-idle episodes were lost")
        try expect(summary.presentIdleRuns.rightCensoredCount == 1, "censoring was not tracked")
        try expect(summary.presentIdleRuns.median == 5, "Kaplan-Meier median is wrong")
        try expect(summary.presentIdleRuns.p90 == nil, "an unidentifiable censored P90 was invented")
    }

    do {
        let start = Date(timeIntervalSince1970: 13_000)
        let records = [
            record(
                at: start.addingTimeInterval(-8),
                idle: 0,
                observation: .unknown,
                event: "inputAnchor"
            ),
            record(at: start.addingTimeInterval(-6), idle: 2, observation: .unknown),
            record(at: start.addingTimeInterval(-4), idle: 4, observation: .unknown),
            record(at: start.addingTimeInterval(-2), idle: 6, observation: .unknown),
            record(at: start, idle: 8, observation: .present),
            record(at: start.addingTimeInterval(2), idle: 10, observation: .unknown),
            record(at: start.addingTimeInterval(4), idle: 12, observation: .unknown),
            record(at: start.addingTimeInterval(6), idle: 14, observation: .present),
            record(at: start.addingTimeInterval(8), idle: 16, observation: .present)
        ]
        let summary = StatisticsEngine.summarize(records: records)
        try expect(summary.presentIdleRuns.count == 2, "unknown did not split supported presence")
        try expect(summary.presentIdleRuns.maximum == 8, "unknown time was claimed as presence")
    }

    do {
        let start = Date(timeIntervalSince1970: 14_000)
        let records = [
            record(at: start, idle: 600, observation: .unknown),
            record(at: start.addingTimeInterval(2), idle: 602, observation: .present),
            record(at: start.addingTimeInterval(4), idle: 604, observation: .present)
        ]
        let summary = StatisticsEngine.summarize(records: records)
        try expect(
            summary.presentIdleRuns.maximum == 2,
            "pre-launch idle time was claimed as observed continuous presence"
        )
    }

    do {
        let start = Date(timeIntervalSince1970: 15_000)
        let prediction = record(at: start, idle: 30, observation: .absent, event: "wouldLock")
        let orphanID = UUID()
        let summary = StatisticsEngine.summarize(
            records: [prediction],
            feedback: [
                PredictionFeedback(predictionID: prediction.id, timestamp: start, label: .confirmedDeparture),
                PredictionFeedback(predictionID: prediction.id, timestamp: start.addingTimeInterval(1), label: .falseAlarm),
                PredictionFeedback(predictionID: orphanID, timestamp: start, label: .confirmedDeparture)
            ]
        )
        try expect(summary.confirmedDepartures == 0, "superseded feedback was counted")
        try expect(summary.falseAlarms == 1, "latest feedback was not used")
    }

    do {
        let departureStart = Date(timeIntervalSince1970: 17_000)
        let departurePredictionID = UUID()
        var records = [8.0, 13, 18, 23, 28, 33].map { idle in
            record(
                at: departureStart.addingTimeInterval(idle),
                idle: idle,
                observation: idle == 8 ? .present : .absent
            )
        }
        records[records.count - 1] = ObservationRecord(
            id: departurePredictionID,
            timestamp: departureStart.addingTimeInterval(33),
            idleSeconds: 33,
            observation: .absent,
            confidence: 0.9,
            cameraAvailable: true,
            state: .triggered,
            mode: .learning,
            event: "wouldLock"
        )

        let falseAlarmStart = departureStart.addingTimeInterval(100)
        let falseAlarmPredictionID = UUID()
        let falseAlarmEpisodeID = UUID()
        var falseAlarmRecords = [8.0, 13, 18, 23, 28].map { idle in
            record(
                at: falseAlarmStart.addingTimeInterval(idle),
                idle: idle,
                observation: idle == 8 ? .present : .absent
            )
        }
        falseAlarmRecords[falseAlarmRecords.count - 1] = ObservationRecord(
            id: falseAlarmPredictionID,
            timestamp: falseAlarmStart.addingTimeInterval(28),
            idleSeconds: 28,
            observation: .absent,
            confidence: 0.9,
            cameraAvailable: true,
            state: .triggered,
            mode: .learning,
            event: "wouldLock"
        )
        falseAlarmRecords.append(ObservationRecord(
            id: falseAlarmEpisodeID,
            timestamp: falseAlarmStart.addingTimeInterval(29),
            idleSeconds: 28,
            observation: .unknown,
            confidence: 0,
            cameraAvailable: false,
            state: .active,
            mode: .learning,
            event: "inputResumed"
        ))
        records.append(contentsOf: falseAlarmRecords)

        let evaluations = ThresholdReplay.evaluate(
            records: records,
            feedback: [
                PredictionFeedback(
                    predictionID: departurePredictionID,
                    timestamp: departureStart.addingTimeInterval(34),
                    label: .confirmedDeparture
                )
            ],
            episodeFeedback: [
                IdleEpisodeFeedback(
                    // Episode-end feedback gives the replay a label independently of whether
                    // the baseline algorithm happened to predict on this episode.
                    episodeID: falseAlarmEpisodeID,
                    timestamp: falseAlarmStart.addingTimeInterval(29),
                    label: .stayedPresent
                )
            ],
            candidates: [
                ThresholdCandidate(
                    probeIdleSeconds: 8,
                    absenceConfirmationSeconds: 10,
                    warningSeconds: 5
                ),
                ThresholdCandidate(
                    probeIdleSeconds: 8,
                    absenceConfirmationSeconds: 12,
                    warningSeconds: 5
                ),
                ThresholdCandidate(
                    probeIdleSeconds: 60,
                    absenceConfirmationSeconds: 20,
                    warningSeconds: 5
                )
            ]
        )
        try expect(
            evaluations[0].confirmedDeparturesCaught == 0,
            "a trigger before confirmed departure timing was promoted to a catch"
        )
        try expect(evaluations[0].unlabeledPredictions == 1, "premature timing was not left unknown")
        try expect(evaluations[0].falseAlarmsTriggered == 1, "fast replay missed a false alarm")
        try expect(evaluations[1].confirmedDeparturesCaught == 1, "safer replay missed a departure")
        try expect(evaluations[1].falseAlarmsTriggered == 0, "safer replay produced a false alarm")
        try expect(
            evaluations[2].eligibleEpisodes == evaluations[0].eligibleEpisodes,
            "candidate probes were compared on different cohorts"
        )
        try expect(evaluations[2].confirmedDepartures == 1, "short departure vanished below a long probe")
        try expect(evaluations[2].confirmedDeparturesCaught == 0, "long probe did not record a miss")
    }

    do {
        let start = Date(timeIntervalSince1970: 19_000)
        let boundaryID = UUID()
        let records = [
            record(at: start, idle: 8, observation: .present),
            record(at: start.addingTimeInterval(20), idle: 28, observation: .absent),
            record(at: start.addingTimeInterval(25), idle: 33, observation: .absent),
            record(at: start.addingTimeInterval(30), idle: 38, observation: .absent),
            record(at: start.addingTimeInterval(35), idle: 43, observation: .absent),
            ObservationRecord(
                id: boundaryID,
                timestamp: start.addingTimeInterval(36),
                idleSeconds: 43,
                observation: .unknown,
                confidence: 0,
                cameraAvailable: false,
                state: .launchGuard,
                mode: .learning,
                event: "episodeBoundary"
            )
        ]
        let evaluation = ThresholdReplay.evaluate(
            records: records,
            feedback: [],
            episodeFeedback: [
                IdleEpisodeFeedback(episodeID: boundaryID, label: .stayedPresent)
            ],
            candidates: [ThresholdCandidate(
                probeIdleSeconds: 8,
                absenceConfirmationSeconds: 10,
                warningSeconds: 5
            )]
        )[0]
        try expect(
            evaluation.falseAlarmsTriggered == 0,
            "a post-gap absent segment was incorrectly primed with synthetic input"
        )
    }

    do {
        let start = Date(timeIntervalSince1970: 19_250)
        let episodeID = UUID()
        let records = [
            record(at: start, idle: 0, observation: .unknown, event: "inputAnchor"),
            record(at: start.addingTimeInterval(2), idle: 2, observation: .unknown),
            record(at: start.addingTimeInterval(4), idle: 4, observation: .unknown),
            record(at: start.addingTimeInterval(6), idle: 6, observation: .unknown),
            record(at: start.addingTimeInterval(8), idle: 8, observation: .absent),
            record(at: start.addingTimeInterval(13), idle: 13, observation: .absent),
            record(at: start.addingTimeInterval(18), idle: 18, observation: .absent),
            record(at: start.addingTimeInterval(23), idle: 23, observation: .absent),
            ObservationRecord(
                id: episodeID,
                timestamp: start.addingTimeInterval(24),
                idleSeconds: 23,
                observation: .unknown,
                confidence: 0,
                cameraAvailable: false,
                state: .active,
                mode: .learning,
                event: "inputResumed"
            )
        ]
        let evaluation = ThresholdReplay.evaluate(
            records: records,
            feedback: [],
            episodeFeedback: [IdleEpisodeFeedback(episodeID: episodeID, label: .stayedPresent)],
            candidates: [ThresholdCandidate(
                probeIdleSeconds: 8,
                absenceConfirmationSeconds: 10,
                warningSeconds: 5
            )]
        )[0]
        try expect(evaluation.falseAlarmsTriggered == 1, "input anchor did not prime replay")
    }

    do {
        let start = Date(timeIntervalSince1970: 19_375)
        let records = [
            record(at: start, idle: 0, observation: .unknown, event: "inputAnchor"),
            record(at: start.addingTimeInterval(2), idle: 2, observation: .unknown),
            record(at: start.addingTimeInterval(4), idle: 4, observation: .unknown),
            record(at: start.addingTimeInterval(6), idle: 6, observation: .unknown),
            record(at: start.addingTimeInterval(8), idle: 8, observation: .absent),
            record(at: start.addingTimeInterval(13), idle: 13, observation: .absent),
            record(at: start.addingTimeInterval(18), idle: 18, observation: .absent),
            record(at: start.addingTimeInterval(23), idle: 23, observation: .absent)
        ]
        let evaluation = ThresholdReplay.evaluate(
            records: records,
            feedback: [],
            candidates: [ThresholdCandidate(
                probeIdleSeconds: 8,
                absenceConfirmationSeconds: 10,
                warningSeconds: 5
            )]
        )[0]
        try expect(
            evaluation.unlabeledPredictions == 1,
            "an active partial-episode prediction vanished from uncertainty counts"
        )
    }

    do {
        let start = Date(timeIntervalSince1970: 19_500)
        let episodeID = UUID()
        var records = [
            record(at: start.addingTimeInterval(8), idle: 8, observation: .present)
        ]
        records.append(contentsOf: [13.0, 18, 23, 28].map { idle in
            record(
                at: start.addingTimeInterval(idle),
                idle: idle,
                observation: .absent,
                readingAgeSeconds: 10
            )
        })
        records.append(ObservationRecord(
            id: episodeID,
            timestamp: start.addingTimeInterval(29),
            idleSeconds: 28,
            observation: .unknown,
            confidence: 0,
            cameraAvailable: false,
            state: .active,
            mode: .learning,
            event: "inputResumed"
        ))
        let evaluation = ThresholdReplay.evaluate(
            records: records,
            feedback: [],
            episodeFeedback: [IdleEpisodeFeedback(episodeID: episodeID, label: .stayedPresent)],
            candidates: [ThresholdCandidate(
                probeIdleSeconds: 8,
                absenceConfirmationSeconds: 10,
                warningSeconds: 5
            )]
        )[0]
        try expect(evaluation.falseAlarmsTriggered == 0, "stale replay samples caused a trigger")
    }

    do {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try JSONLEventStore(directoryURL: directory)
        let sample = record(at: Date(timeIntervalSince1970: 20_000), idle: 12, observation: .present)
        try store.append(sample)
        try store.append(PredictionFeedback(predictionID: sample.id, label: .confirmedDeparture))
        try store.append(IdleEpisodeFeedback(episodeID: sample.id, label: .stayedPresent))
        let loadedRecords = try store.loadObservationRecords()
        let loadedFeedback = try store.loadFeedback()
        let loadedEpisodeFeedback = try store.loadEpisodeFeedback()
        try expect(loadedRecords == [sample], "event store round-trip failed")
        try expect(loadedFeedback.count == 1, "feedback round-trip failed")
        try expect(loadedEpisodeFeedback.count == 1, "episode feedback round-trip failed")

        let observationURL = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first { $0.lastPathComponent.hasPrefix("observations-") }!
        let handle = try FileHandle(forWritingTo: observationURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{truncated".utf8))
        try handle.close()
        let recoveredRecords = try store.loadObservationRecords()
        try expect(
            recoveredRecords == [sample],
            "a truncated final JSONL append hid earlier valid records"
        )

        let second = record(at: sample.timestamp.addingTimeInterval(1), idle: 13, observation: .absent)
        try store.append(second)
        let afterRepair = try store.loadObservationRecords()
        try expect(afterRepair == [sample, second], "next append turned a partial tail into interior corruption")

        let complete = try FileHandle(forUpdating: observationURL)
        let fileSize = try complete.seekToEnd()
        try complete.truncate(atOffset: fileSize - 1)
        try complete.seekToEnd()
        // A valid tail can begin in a previous scan chunk.
        try complete.write(contentsOf: Data(repeating: 0x20, count: 5000))
        try complete.close()
        let noNewline = try store.loadObservationRecords()
        try expect(noNewline == [sample, second], "reader lost an intact unterminated record")
        let third = record(at: sample.timestamp.addingTimeInterval(2), idle: 14, observation: .absent)
        try store.append(third)
        let afterMissingNewline = try store.loadObservationRecords()
        try expect(afterMissingNewline == [sample, second, third], "recovery removed or merged a complete final record")

        // Preserve complete values with unknown schemas rather than erasing user data.
        let unknownSchema = Data(#"{"futureSchema":1}"#.utf8)
        let raw = try FileHandle(forWritingTo: observationURL)
        try raw.seekToEnd()
        try raw.write(contentsOf: unknownSchema)
        try raw.close()
        try store.append(third)
        let withFutureRecord = try Data(contentsOf: observationURL)
        try expect(withFutureRecord.range(of: unknownSchema + Data([0x0A])) != nil,
                   "repair discarded a syntactically complete final value")
        do {
            _ = try store.loadObservationRecords()
            throw CheckFailure.failed("schema mismatch in a complete interior record was ignored")
        } catch is DecodingError {}

        try store.deleteAll()
        let recordsAfterDeletion = try store.loadObservationRecords()
        let episodeFeedbackAfterDeletion = try store.loadEpisodeFeedback()
        try expect(recordsAfterDeletion.isEmpty, "event deletion failed")
        try expect(episodeFeedbackAfterDeletion.isEmpty, "episode feedback deletion failed")
    }
}

do {
    try runChecks()
    print("PresenceLockCoreChecks: all checks passed")
} catch {
    fputs("PresenceLockCoreChecks failed: \(error)\n", stderr)
    exit(1)
}
