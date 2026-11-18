import Foundation
import PresenceLockCore

enum SummaryFormatter {
    static func markdown(
        _ summary: LearningSummary,
        passive: PassiveEpisodeSummary,
        replay: [ThresholdEvaluation] = [],
        verification: DecisionReplayVerification
    ) -> String {
        let generated = DateFormatter.localizedString(
            from: Date(),
            dateStyle: .medium,
            timeStyle: .short
        )
        let replaySection = thresholdReplayMarkdown(replay, verification: verification)
        let manualPresenceSection = manualPresenceMarkdown(summary.confirmedPresentIdleEpisodes)

        return """
        # PresenceLock — отчёт обучения

        Сформирован: \(generated)

        - Наблюдений: \(summary.sampleCount)
        - Прогнозов блокировки: \(summary.predictedLocks)
        - Прогнозов, размеченных как реальный уход: \(summary.confirmedDepartures)
        - Прогнозов, размеченных как ложная тревога: \(summary.falseAlarms)

        \(passiveMarkdown(passive))

        \(manualPresenceSection)

        ## Присутствие по наблюдениям камеры

        - Эпизодов: \(summary.presentIdleRuns.count)
        - Из них право-цензурированных (конец, разрыв или `unknown`): \(summary.presentIdleRuns.rightCensoredCount)
        - Медиана: \(format(summary.presentIdleRuns.median))
        - P90: \(format(summary.presentIdleRuns.p90))
        - P95: \(format(summary.presentIdleRuns.p95))
        - P99: \(format(summary.presentIdleRuns.p99))
        - Максимум: \(format(summary.presentIdleRuns.maximum))

        Квантили этого раздела оценены методом Каплана–Майера с учётом незавершённых эпизодов. «—» означает, что накопленных завершений пока недостаточно для честной оценки.

        ## Наблюдаемое отсутствие

        - Эпизодов: \(summary.absenceRuns.count)
        - Медиана: \(format(summary.absenceRuns.median))
        - P95: \(format(summary.absenceRuns.p95))
        - Максимум: \(format(summary.absenceRuns.maximum))

        Длительность считается по пригодным наблюдениям. Паузы с зарегистрированным предпросмотром исключены из обеих сводок камеры. В старых записях режим предпросмотра и время кадра могли отсутствовать.

        \(replaySection)

        > Это техническая сводка, а не доказательство надёжности. Реальную блокировку нельзя включать до отдельного теневого периода без подтверждённых ложных тревог.
        """
    }

    private static func passiveMarkdown(_ summary: PassiveEpisodeSummary) -> String {
        let total = summary.likelyPresent + summary.likelyAway + summary.uncertain
        let heading = "## Что происходило во время пауз без ввода"
        guard total > 0 else {
            return """
            \(heading)

            Пока нет подходящих завершённых пауз для автоматической оценки. Продолжайте пользоваться Mac как обычно.
            """
        }
        var durations = ""
        if summary.likelyPresent > 0 {
            durations = "Медиана пауз с вероятным присутствием — \(format(summary.presentIdleMedian)), самая длинная — \(format(summary.presentIdleMaximum))."
            if summary.likelyPresent >= 10 {
                durations += " Примерно девять из десяти таких пауз укладываются в \(format(summary.presentIdleP90))."
            }
            durations += " Длительность включает ожидание камеры после последнего действия мышью или клавиатурой."
        }
        return """
        \(heading)

        Из \(total) завершённых пауз без ручной оценки:

        - Вероятно, человек оставался у экрана — \(summary.likelyPresent).
        - Камера видела устойчивое отсутствие человека — \(summary.likelyAway).
        - Показаний недостаточно или они неоднозначны — \(summary.uncertain).

        \(durations)

        Оценка строится по подробным наблюдениям в обычном режиме. Эпизоды предпросмотра, прерванные паузы и записи старого формата пропускаются. Камера замечает любого человека в кадре. В статистику подтверждённых уходов и ложных тревог входят только ваши отметки.
        """
    }

    private static func manualPresenceMarkdown(_ summary: DurationSummary) -> String {
        let heading = "## Время у экрана без ввода по вашим отметкам"
        guard summary.count > 0 else {
            return """
            \(heading)

            Ручных отметок о присутствии в завершённых паузах пока нет. При желании последнее наблюдение можно уточнить в меню PresenceLock.
            """
        }

        return """
        \(heading)

        - Размеченных эпизодов: \(summary.count)
        - Медиана: \(format(summary.median))
        - P90: \(format(summary.p90))
        - Максимум: \(format(summary.maximum))

        Длительность включает всю паузу между действиями, в том числе время до первого кадра камеры. Здесь учтены эпизоды, завершившиеся новым вводом без записанного разрыва сессии. P90 описывает текущую выборку размеченных эпизодов.
        """
    }

    private static func thresholdReplayMarkdown(
        _ replay: [ThresholdEvaluation],
        verification: DecisionReplayVerification
    ) -> String {
        let verificationSection = verificationMarkdown(verification)
        guard !replay.isEmpty else {
            return """
            ## Сравнение порогов

            \(verificationSection)

            Пока недостаточно данных для повторного прогона порогов.
            """
        }

        guard replay.contains(where: { $0.labeledEpisodeCount > 0 }) else {
            guard replay.contains(where: { $0.eligibleEpisodes > 0 || $0.unlabeledPredictions > 0 }) else {
                return """
                ## Сравнение порогов

                \(verificationSection)

                Пока недостаточно подходящих наблюдений для сравнения.
                """
            }
            let rows = replay.map { evaluation in
                let candidate = evaluation.candidate
                return "| \(format(candidate.probeIdleSeconds)) | \(format(candidate.absenceConfirmationSeconds)) + \(format(candidate.warningSeconds)) | \(evaluation.unlabeledPredictions) | \(format(evaluation.estimatedCameraSeconds)) |"
            }.joined(separator: "\n")
            return """
            ## Сравнение порогов без ручных отметок

            \(verificationSection)

            | Камера после | Отсутствие + предупреждение | Пауз хотя бы с одним прогнозом | Оценка времени камеры |
            |---:|---:|---:|---:|
            \(rows)

            Один и тот же журнал проверен при разных настройках. Число пауз включает ещё открытые эпизоды с прогнозом. По этой таблице можно сравнить частоту срабатываний. Их правильность без независимого подтверждения неизвестна.
            """
        }

        func fraction(_ matches: Int, of total: Int) -> String {
            total > 0 ? "\(matches)/\(total)" : "—"
        }
        let rows = replay.map { evaluation in
            let candidate = evaluation.candidate
            return "| \(format(candidate.probeIdleSeconds)) | \(format(candidate.absenceConfirmationSeconds)) + \(format(candidate.warningSeconds)) | \(fraction(evaluation.labeledEpisodes, of: evaluation.eligibleEpisodes)) | \(fraction(evaluation.confirmedDeparturesCaught, of: evaluation.confirmedDepartures)) | \(fraction(evaluation.falseAlarmsTriggered, of: evaluation.falseAlarmEpisodes)) | \(fraction(evaluation.departuresWithUnknownTimingWithoutPrediction, of: evaluation.departuresWithUnknownTiming)) | \(evaluation.unlabeledPredictions) | \(evaluation.conflictingEpisodes) | \(format(evaluation.medianDetectionLatency)) | \(format(evaluation.estimatedCameraSeconds)) |"
        }.joined(separator: "\n")

        let coverage = replay[0]
        return """
        ## Повторный прогон порогов

        \(verificationSection)

        В сравнение вошло подробных эпизодов: \(coverage.trackedEpisodes). Исключено из-за предпросмотра, старого формата, неполных данных, расхождений при сверке или недоступных показаний камеры: \(coverage.excludedEpisodes).

        Эпизодов с новой проверкой отсчёта и кадра: \(coverage.episodesWithNewCountdownEvidence). По старым записям воспроизводится поведение прежнего отсчёта.

        | Камера после | Отсутствие + предупреждение | Размечено | После ухода с подтверждённым временем | При подтверждённом присутствии | Без прогноза / уходов без времени | Исход неясен | Конфликты | От обнаружения отсутствия до решения | Наблюдаемая камера |
        |---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        \(rows)

        «После ухода с подтверждённым временем» засчитывается, когда кандидат сработал не раньше прогноза, который вы отдельно подтвердили как своевременный. Метка «я отходил» учитывается в отдельном столбце и не сообщает точное время ухода.

        «Исход неясен» — число срабатываний кандидата без временно однозначной метки, включая ещё не завершённые эпизоды.

        При изменении момента включения камеры и длительности проверки используются уже записанные показания. Время запуска и частота опроса в реальном запуске могут отличаться. При выборе порога учитывайте покрытие, предупреждения при подтверждённом присутствии и уходы без прогноза. Проверьте выбранные пороги в теневом режиме на новых данных.

        «Наблюдаемая камера» — нижняя сравнительная оценка по связным участкам журнала, а не измерение расхода батареи.
        """
    }

    private static func verificationMarkdown(_ result: DecisionReplayVerification) -> String {
        guard result.checkedEpisodes > 0 else {
            return "Сверка с реальными решениями ожидает завершённых эпизодов из новых записей. Неполных записей: \(result.incompleteTraces)."
        }
        let status = result.matchingEpisodes == result.checkedEpisodes
            ? "Решения совпали во всех проверенных эпизодах."
            : "Есть расхождения. Проверьте их перед выбором порогов."
        return "Сверка при исходных настройках: \(result.matchingEpisodes)/\(result.checkedEpisodes) эпизодов. "
            + "Прогнозов в журнале: \(result.recordedPredictions), при повторном прогоне: \(result.replayedPredictions). "
            + "Из проверенных ещё продолжаются: \(result.checkedOpenEpisodes). "
            + "Неполных записей: \(result.incompleteTraces). \(status)"
    }

    private static func format(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        if value < 60 { return String(format: "%.0f с", value) }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return "\(minutes) мин \(seconds) с"
    }
}
