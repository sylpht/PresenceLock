import Foundation

public enum PoseShadowResult: String, Codable, Equatable, Sendable {
    case torsoDetected, noReliableTorso, unavailable
}

/// One optional pose analysis result. The camera frame and body landmarks are never persisted.
public struct PoseShadowSample: Codable, Equatable, Sendable {
    public let capturedAtMonotonic: TimeInterval
    public let result: PoseShadowResult

    public init(capturedAtMonotonic: TimeInterval, result: PoseShadowResult) {
        self.capturedAtMonotonic = capturedAtMonotonic
        self.result = result
    }
}

public struct PoseShadowSummary: Equatable, Sendable {
    public fileprivate(set) var torsoFrames = 0
    public fileprivate(set) var noTorsoFrames = 0
    public fileprivate(set) var unavailableFrames = 0
    public fileprivate(set) var corroboratedEpisodes = 0
    public fileprivate(set) var assessedWarnings = 0
    public fileprivate(set) var warningsWithSupport = 0
    public fileprivate(set) var assessedPredictions = 0
    public fileprivate(set) var predictionsWithSupport = 0
    public var sampledFrames: Int { torsoFrames + noTorsoFrames + unavailableFrames }
    public var sampledEpisodes: Int { sampledEpisodeStartIDs.count }

    // Identifiers used only to pair the same inputs during an in-memory policy comparison.
    fileprivate(set) var sampledEpisodeStartIDs: Set<UUID> = []
    fileprivate(set) var corroboratedTickIDs: Set<UUID> = []
}

public enum PoseShadowAnalysis {
    private static let supportWindow: TimeInterval = 5

    public static func summarize(records: [ObservationRecord]) -> PoseShadowSummary {
        var summary = PoseShadowSummary()
        var episode: [ObservationRecord] = []
        for record in records.sorted(by: { $0.timestamp < $1.timestamp }) {
            switch record.event {
            case "idleStarted":
                episode = [record]
            case "idleUnanchored", "sessionBoundary", "episodeBoundary", "inputAnchor":
                episode.removeAll(keepingCapacity: true)
            case "inputResumed":
                guard !episode.isEmpty else { continue }
                episode.append(record)
                if episode.contains(where: { $0.replayTick?.poseShadow != nil }),
                   isCompleteTrace(episode) {
                    accumulate(episode, into: &summary)
                }
                episode.removeAll(keepingCapacity: true)
            default:
                if !episode.isEmpty, !record.isLockRequestDiagnostic { episode.append(record) }
            }
        }
        return summary
    }

    private static func isCompleteTrace(_ episode: [ObservationRecord]) -> Bool {
        guard let header = episode.first, let first = header.replayTick,
              let config = first.configuration, let end = episode.last,
              end.replayTick?.inputOccurred == true, end.state == .active else { return false }
        let anchor = first.monotonicTime - first.idleSeconds
        var previous: DecisionReplayTick?
        for record in episode {
            guard record.mode == header.mode, record.mode != .armed else { return false }
            guard let tick = record.replayTick else {
                if record.event == nil { return false }
                continue
            }
            guard tick.cameraEvidence != nil, tick.cameraPreviewActive != true,
                  tick.monotonicTime.isFinite, tick.idleSeconds.isFinite, tick.idleSeconds >= 0,
                  tick.updateGapSeconds.isFinite, tick.updateGapSeconds >= 0,
                  tick.updateGapSeconds <= config.maximumUpdateGapSeconds else { return false }
            if let previous {
                let elapsed = tick.monotonicTime - previous.monotonicTime
                guard elapsed > 0, abs(elapsed - tick.updateGapSeconds) < 0.001 else { return false }
            }
            if tick.inputOccurred {
                guard record.event == "inputResumed", let previous,
                      abs(previous.idleSeconds - end.idleSeconds) <= config.maximumUpdateGapSeconds
                else { return false }
            } else if abs((tick.monotonicTime - tick.idleSeconds) - anchor) > 0.25 {
                return false
            }
            previous = tick
        }
        return true
    }

    private struct AbsenceRun {
        let firstCapture: TimeInterval
        var latestBaselineCapture: TimeInterval
        var lastUsablePose: TimeInterval?
        var lastTorso: TimeInterval?
        var corroboratedAt: TimeInterval?

        mutating func observe(_ sample: PoseShadowSample) -> Bool {
            let capture = sample.capturedAtMonotonic
            if sample.result == .unavailable {
                lastUsablePose = nil
            } else {
                lastUsablePose = capture
            }
            guard sample.result == .torsoDetected else {
                lastTorso = nil
                corroboratedAt = nil
                return false
            }
            let agrees = lastTorso.map { capture - $0 <= PoseShadowAnalysis.supportWindow } ?? false
            lastTorso = capture
            corroboratedAt = agrees ? capture : nil
            return agrees
        }
    }

    private static func accumulate(_ episode: [ObservationRecord], into summary: inout PoseShadowSummary) {
        guard let header = episode.first, let config = header.replayTick?.configuration else { return }
        var run: AbsenceRun?
        var lastSampleTime: TimeInterval?
        var decisionTime: TimeInterval?
        var tickTimestamp: Date?
        var hadCorroboration = false
        for record in episode {
            if let tick = record.replayTick {
                tickTimestamp = record.timestamp
                decisionTime = tick.monotonicTime
                guard !tick.inputOccurred, tick.idleSeconds >= config.probeIdleSeconds,
                      record.state == .suspectedAway || record.state == .warning || record.state == .triggered,
                      record.cameraAvailable, record.observation == .absent,
                      tick.cameraEvidence?.sawPresence == false, tick.cameraEvidence?.sawUncertainty == false,
                      let age = record.readingAgeSeconds, age.isFinite, age >= 0, age <= config.maximumSampleAgeSeconds
                else {
                    run = nil
                    continue
                }
                let baselineCapture = tick.monotonicTime - age
                if let last = run?.latestBaselineCapture,
                   baselineCapture < last - 0.001 || baselineCapture - last > config.maximumSampleAgeSeconds {
                    run = nil
                }
                if run == nil { run = AbsenceRun(firstCapture: baselineCapture, latestBaselineCapture: baselineCapture) }
                run?.latestBaselineCapture = baselineCapture
                if let sample = tick.poseShadow, let firstCapture = run?.firstCapture {
                    let capture = sample.capturedAtMonotonic
                    let age = tick.monotonicTime - capture
                    if capture.isFinite, capture >= firstCapture - 0.001, age >= 0, age <= config.maximumSampleAgeSeconds,
                       lastSampleTime.map({ capture - $0 >= 0.001 }) ?? true {
                        lastSampleTime = capture
                        summary.sampledEpisodeStartIDs.insert(header.id)
                        switch sample.result {
                        case .torsoDetected: summary.torsoFrames += 1
                        case .noReliableTorso: summary.noTorsoFrames += 1
                        case .unavailable: summary.unavailableFrames += 1
                        }
                        if run?.observe(sample) == true {
                            hadCorroboration = true
                            summary.corroboratedTickIDs.insert(record.id)
                        }
                    }
                }
            } else if record.event == "warningAcknowledged" || record.event == "warningCancelled" {
                run = nil
                continue
            }
            // A companion action row has the wall timestamp of its journaled decision tick.
            guard record.timestamp == tickTimestamp, let now = decisionTime,
                  let usable = run?.lastUsablePose, now - usable <= supportWindow else { continue }
            let supported = run?.corroboratedAt.map { now - $0 <= supportWindow } ?? false
            switch record.event {
            case "warningStarted":
                summary.assessedWarnings += 1
                if supported { summary.warningsWithSupport += 1 }
            case "wouldLock":
                summary.assessedPredictions += 1
                if supported { summary.predictionsWithSupport += 1 }
            default: break
            }
        }
        if hadCorroboration { summary.corroboratedEpisodes += 1 }
    }
}
