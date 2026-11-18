import Foundation
import PresenceLockCore

enum LearningReport {
    static func make(store: JSONLEventStore, configuration: DetectionConfiguration) throws -> String {
        let records = try store.loadObservationRecords()
        let feedback = try store.loadFeedback()
        let episodeFeedback = try store.loadEpisodeFeedback()
        let maximumGap = max(5, configuration.sampleIntervalSeconds * 2.5)
        let summary = StatisticsEngine.summarize(
            records: records, feedback: feedback, episodeFeedback: episodeFeedback,
            maximumGap: maximumGap, probeIdleSeconds: configuration.probeIdleSeconds
        )
        let replay = ThresholdReplay.evaluate(
            records: records, feedback: feedback, episodeFeedback: episodeFeedback,
            candidates: ThresholdReplay.defaultGrid(
                minimumProbeSeconds: configuration.probeIdleSeconds, currentConfiguration: configuration
            ),
            maximumEpisodeGap: maximumGap, includeLegacy: false
        )
        let passive = PassiveEpisodeAnalysis.summarize(
            records: records, episodeFeedback: episodeFeedback, predictionFeedback: feedback
        )
        let verification = ThresholdReplay.verifyReferenceDecisions(records: records, maximumEpisodeGap: maximumGap)
        let pose = PoseShadowAnalysis.summarize(records: records)
        let comparison = ThresholdReplay.comparePoseShadow(records: records, summary: pose)
        let markdown = SummaryFormatter.markdown(summary, passive: passive, replay: replay, verification: verification)
            + poseSection(pose, comparison: comparison)
        let outcomes = records.filter(\.isLockRequestDiagnostic)
        guard !outcomes.isEmpty else { return markdown }
        return markdown + """


        ## Запросы блокировки в боевом режиме

        - Отменено при последней проверке — \(outcomes.filter { $0.event == "lockSuppressed" }.count).
        - macOS приняла запрос — \(outcomes.filter { $0.event == "lockRequestAccepted" }.count).
        - При выполнении произошла ошибка — \(outcomes.filter { $0.event == "lockFailed" }.count).

        Здесь учтены записанные ответы на запросы. Для проверки входа после блокировки требуется отдельная проверка на Mac.
        """
    }

    private static func poseSection(_ pose: PoseShadowSummary, comparison: PosePolicyComparison) -> String {
        let heading = "\n\n## Эксперимент по распознаванию позы"
        guard pose.sampledFrames > 0 else {
            return heading + "\n\nВ завершённых паузах без предпросмотра пока нет подходящих проверок позы. Старые записи без такой проверки пропускаются."
        }
        var section = heading + """


        Проверено отдельных кадров — \(pose.sampledFrames), завершённых пауз — \(pose.sampledEpisodes). Корпус обнаружен в \(pose.torsoFrames) кадрах. Кадров без уверенного результата о корпусе — \(pose.noTorsoFrames), технически недоступных проверок — \(pose.unavailableFrames).

        В \(pose.corroboratedEpisodes) паузах модель обнаружила корпус в двух отдельных проверках подряд в пределах пяти секунд, пока основной детектор считал место пустым. К моменту предупреждения такой сигнал был свежим в \(pose.warningsWithSupport) из \(pose.assessedWarnings) предупреждений с доступной проверкой. К моменту прогноза блокировки — в \(pose.predictionsWithSupport) из \(pose.assessedPredictions) прогнозов с доступной проверкой.
        """
        if comparison.episodes > 0 {
            section += """


            Для \(comparison.episodes) пауз удалось воспроизвести исходные решения. На тех же записанных показаниях исходный алгоритм дал \(comparison.baselineWarnings) предупреждений и \(comparison.baselinePredictions) прогнозов блокировки, вариант с проверкой позы — \(comparison.candidateWarnings) и \(comparison.candidatePredictions) соответственно.
            """
            if let seconds = comparison.medianFirstPredictionDelay {
                let value = String(format: "%+.1f", seconds)
                section += " Медианная разница во времени первого прогноза для пауз, где сработали оба варианта, — \(value) с."
            }
        }
        return section + "\n\nПроверка позы работает в фоне в обучении и теневом режиме. Обнаруженный корпус может принадлежать любому человеку в кадре. По этим сравнениям нельзя установить, какие блокировки действительно были бы ошибочными."
    }
}
