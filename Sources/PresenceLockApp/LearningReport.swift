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
        return markdown + L10n.format("""


        ## Запросы блокировки в боевом режиме

        - Отменено при последней проверке — %1$ld.
        - macOS приняла запрос — %2$ld.
        - При выполнении произошла ошибка — %3$ld.

        Здесь учтены записанные ответы на запросы. Для проверки входа после блокировки требуется отдельная проверка на Mac.
        """,
            outcomes.filter { $0.event == "lockSuppressed" }.count,
            outcomes.filter { $0.event == "lockRequestAccepted" }.count,
            outcomes.filter { $0.event == "lockFailed" }.count
        )
    }

    private static func poseSection(_ pose: PoseShadowSummary, comparison: PosePolicyComparison) -> String {
        let heading = L10n.text("\n\n## Эксперимент по распознаванию позы")
        guard pose.sampledFrames > 0 else {
            return heading + L10n.text("\n\nВ завершённых паузах без предпросмотра пока нет подходящих проверок позы. Старые записи без такой проверки пропускаются.")
        }
        var section = heading + L10n.format("""


        Проверено отдельных кадров — %1$ld, завершённых пауз — %2$ld. Корпус обнаружен в %3$ld кадрах. Кадров без уверенного результата о корпусе — %4$ld, технически недоступных проверок — %5$ld.

        В %6$ld паузах модель обнаружила корпус в двух отдельных проверках подряд в пределах пяти секунд, пока основной детектор считал место пустым. К моменту предупреждения такой сигнал был свежим в %7$ld из %8$ld предупреждений с доступной проверкой. К моменту прогноза блокировки — в %9$ld из %10$ld прогнозов с доступной проверкой.
        """,
            pose.sampledFrames,
            pose.sampledEpisodes,
            pose.torsoFrames,
            pose.noTorsoFrames,
            pose.unavailableFrames,
            pose.corroboratedEpisodes,
            pose.warningsWithSupport,
            pose.assessedWarnings,
            pose.predictionsWithSupport,
            pose.assessedPredictions
        )
        if comparison.episodes > 0 {
            section += L10n.format("""


            Для %1$ld пауз удалось воспроизвести исходные решения. На тех же записанных показаниях исходный алгоритм дал %2$ld предупреждений и %3$ld прогнозов блокировки, вариант с проверкой позы — %4$ld и %5$ld соответственно.
            """,
                comparison.episodes,
                comparison.baselineWarnings,
                comparison.baselinePredictions,
                comparison.candidateWarnings,
                comparison.candidatePredictions
            )
            if let seconds = comparison.medianFirstPredictionDelay {
                let value = String(format: "%+.1f", seconds)
                section += L10n.format(" Медианная разница во времени первого прогноза для пауз, где сработали оба варианта, — %1$@ с.", value)
            }
        }
        return section + L10n.text("\n\nПроверка позы работает в фоне в обучении и теневом режиме. Обнаруженный корпус может принадлежать любому человеку в кадре. По этим сравнениям нельзя установить, какие блокировки действительно были бы ошибочными.")
    }
}
