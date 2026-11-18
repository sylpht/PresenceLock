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

        return L10n.format("""
        # PresenceLock — отчёт обучения

        Сформирован: %1$@

        - Наблюдений: %2$ld
        - Прогнозов блокировки: %3$ld
        - Прогнозов, размеченных как реальный уход: %4$ld
        - Прогнозов, размеченных как ложная тревога: %5$ld

        %6$@

        %7$@

        ## Присутствие по наблюдениям камеры

        - Эпизодов: %8$ld
        - Из них право-цензурированных (конец, разрыв или `unknown`): %9$ld
        - Медиана: %10$@
        - P90: %11$@
        - P95: %12$@
        - P99: %13$@
        - Максимум: %14$@

        Квантили этого раздела оценены методом Каплана–Майера с учётом незавершённых эпизодов. «—» означает, что накопленных завершений пока недостаточно для честной оценки.

        ## Наблюдаемое отсутствие

        - Эпизодов: %15$ld
        - Медиана: %16$@
        - P95: %17$@
        - Максимум: %18$@

        Длительность считается по пригодным наблюдениям. Паузы с зарегистрированным предпросмотром исключены из обеих сводок камеры. В старых записях режим предпросмотра и время кадра могли отсутствовать.

        %19$@

        > Это техническая сводка, а не доказательство надёжности. Реальную блокировку нельзя включать до отдельного теневого периода без подтверждённых ложных тревог.
        """,
            generated,
            summary.sampleCount,
            summary.predictedLocks,
            summary.confirmedDepartures,
            summary.falseAlarms,
            passiveMarkdown(passive),
            manualPresenceSection,
            summary.presentIdleRuns.count,
            summary.presentIdleRuns.rightCensoredCount,
            format(summary.presentIdleRuns.median),
            format(summary.presentIdleRuns.p90),
            format(summary.presentIdleRuns.p95),
            format(summary.presentIdleRuns.p99),
            format(summary.presentIdleRuns.maximum),
            summary.absenceRuns.count,
            format(summary.absenceRuns.median),
            format(summary.absenceRuns.p95),
            format(summary.absenceRuns.maximum),
            replaySection
        )
    }

    private static func passiveMarkdown(_ summary: PassiveEpisodeSummary) -> String {
        let total = summary.likelyPresent + summary.likelyAway + summary.uncertain
        let heading = L10n.text("## Что происходило во время пауз без ввода")
        guard total > 0 else {
            return L10n.format("""
            %1$@

            Пока нет подходящих завершённых пауз для автоматической оценки. Продолжайте пользоваться Mac как обычно.
            """,
                heading
            )
        }
        var durations = ""
        if summary.likelyPresent > 0 {
            durations = L10n.format("Медиана пауз с вероятным присутствием — %1$@, самая длинная — %2$@.", format(summary.presentIdleMedian), format(summary.presentIdleMaximum))
            if summary.likelyPresent >= 10 {
                durations += L10n.format(" Примерно девять из десяти таких пауз укладываются в %1$@.", format(summary.presentIdleP90))
            }
            durations += L10n.text(" Длительность включает ожидание камеры после последнего действия мышью или клавиатурой.")
        }
        return L10n.format("""
        %1$@

        Из %2$ld завершённых пауз без ручной оценки:

        - Вероятно, человек оставался у экрана — %3$ld.
        - Камера видела устойчивое отсутствие человека — %4$ld.
        - Показаний недостаточно или они неоднозначны — %5$ld.

        %6$@

        Оценка строится по подробным наблюдениям в обычном режиме. Эпизоды предпросмотра, прерванные паузы и записи старого формата пропускаются. Камера замечает любого человека в кадре. В статистику подтверждённых уходов и ложных тревог входят только ваши отметки.
        """,
            heading,
            total,
            summary.likelyPresent,
            summary.likelyAway,
            summary.uncertain,
            durations
        )
    }

    private static func manualPresenceMarkdown(_ summary: DurationSummary) -> String {
        let heading = L10n.text("## Время у экрана без ввода по вашим отметкам")
        guard summary.count > 0 else {
            return L10n.format("""
            %1$@

            Ручных отметок о присутствии в завершённых паузах пока нет. При желании последнее наблюдение можно уточнить в меню PresenceLock.
            """,
                heading
            )
        }

        return L10n.format("""
        %1$@

        - Размеченных эпизодов: %2$ld
        - Медиана: %3$@
        - P90: %4$@
        - Максимум: %5$@

        Длительность включает всю паузу между действиями, в том числе время до первого кадра камеры. Здесь учтены эпизоды, завершившиеся новым вводом без записанного разрыва сессии. P90 описывает текущую выборку размеченных эпизодов.
        """,
            heading,
            summary.count,
            format(summary.median),
            format(summary.p90),
            format(summary.maximum)
        )
    }

    private static func thresholdReplayMarkdown(
        _ replay: [ThresholdEvaluation],
        verification: DecisionReplayVerification
    ) -> String {
        let verificationSection = verificationMarkdown(verification)
        guard !replay.isEmpty else {
            return L10n.format("""
            ## Сравнение порогов

            %1$@

            Пока недостаточно данных для повторного прогона порогов.
            """,
                verificationSection
            )
        }

        guard replay.contains(where: { $0.labeledEpisodeCount > 0 }) else {
            guard replay.contains(where: { $0.eligibleEpisodes > 0 || $0.unlabeledPredictions > 0 }) else {
                return L10n.format("""
                ## Сравнение порогов

                %1$@

                Пока недостаточно подходящих наблюдений для сравнения.
                """,
                    verificationSection
                )
            }
            let rows = replay.map { evaluation in
                let candidate = evaluation.candidate
                return "| \(format(candidate.probeIdleSeconds)) | \(format(candidate.absenceConfirmationSeconds)) + \(format(candidate.warningSeconds)) | \(evaluation.unlabeledPredictions) | \(format(evaluation.estimatedCameraSeconds)) |"
            }.joined(separator: "\n")
            return L10n.format("""
            ## Сравнение порогов без ручных отметок

            %1$@

            | Камера после | Отсутствие + предупреждение | Пауз хотя бы с одним прогнозом | Оценка времени камеры |
            |---:|---:|---:|---:|
            %2$@

            Один и тот же журнал проверен при разных настройках. Число пауз включает ещё открытые эпизоды с прогнозом. По этой таблице можно сравнить частоту срабатываний. Их правильность без независимого подтверждения неизвестна.
            """,
                verificationSection,
                rows
            )
        }

        func fraction(_ matches: Int, of total: Int) -> String {
            total > 0 ? "\(matches)/\(total)" : "—"
        }
        let rows = replay.map { evaluation in
            let candidate = evaluation.candidate
            return "| \(format(candidate.probeIdleSeconds)) | \(format(candidate.absenceConfirmationSeconds)) + \(format(candidate.warningSeconds)) | \(fraction(evaluation.labeledEpisodes, of: evaluation.eligibleEpisodes)) | \(fraction(evaluation.confirmedDeparturesCaught, of: evaluation.confirmedDepartures)) | \(fraction(evaluation.falseAlarmsTriggered, of: evaluation.falseAlarmEpisodes)) | \(fraction(evaluation.departuresWithUnknownTimingWithoutPrediction, of: evaluation.departuresWithUnknownTiming)) | \(evaluation.unlabeledPredictions) | \(evaluation.conflictingEpisodes) | \(format(evaluation.medianDetectionLatency)) | \(format(evaluation.estimatedCameraSeconds)) |"
        }.joined(separator: "\n")

        let coverage = replay[0]
        return L10n.format("""
        ## Повторный прогон порогов

        %1$@

        В сравнение вошло подробных эпизодов: %2$ld. Исключено из-за предпросмотра, старого формата, неполных данных, расхождений при сверке или недоступных показаний камеры: %3$ld.

        Эпизодов с новой проверкой отсчёта и кадра: %4$ld. По старым записям воспроизводится поведение прежнего отсчёта.

        | Камера после | Отсутствие + предупреждение | Размечено | После ухода с подтверждённым временем | При подтверждённом присутствии | Без прогноза / уходов без времени | Исход неясен | Конфликты | От обнаружения отсутствия до решения | Наблюдаемая камера |
        |---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
        %5$@

        «После ухода с подтверждённым временем» засчитывается, когда кандидат сработал не раньше прогноза, который вы отдельно подтвердили как своевременный. Метка «я отходил» учитывается в отдельном столбце и не сообщает точное время ухода.

        «Исход неясен» — число срабатываний кандидата без временно однозначной метки, включая ещё не завершённые эпизоды.

        При изменении момента включения камеры и длительности проверки используются уже записанные показания. Время запуска и частота опроса в реальном запуске могут отличаться. При выборе порога учитывайте покрытие, предупреждения при подтверждённом присутствии и уходы без прогноза. Проверьте выбранные пороги в теневом режиме на новых данных.

        «Наблюдаемая камера» — нижняя сравнительная оценка по связным участкам журнала, а не измерение расхода батареи.
        """,
            verificationSection,
            coverage.trackedEpisodes,
            coverage.excludedEpisodes,
            coverage.episodesWithNewCountdownEvidence,
            rows
        )
    }

    private static func verificationMarkdown(_ result: DecisionReplayVerification) -> String {
        guard result.checkedEpisodes > 0 else {
            return L10n.format("Сверка с реальными решениями ожидает завершённых эпизодов из новых записей. Неполных записей: %1$ld.", result.incompleteTraces)
        }
        let status = result.matchingEpisodes == result.checkedEpisodes
            ? L10n.text("Решения совпали во всех проверенных эпизодах.")
            : L10n.text("Есть расхождения. Проверьте их перед выбором порогов.")
        return L10n.format("Сверка при исходных настройках: %1$ld/%2$ld эпизодов. ", result.matchingEpisodes, result.checkedEpisodes)
            + L10n.format("Прогнозов в журнале: %1$ld, при повторном прогоне: %2$ld. ", result.recordedPredictions, result.replayedPredictions)
            + L10n.format("Из проверенных ещё продолжаются: %1$ld. ", result.checkedOpenEpisodes)
            + L10n.format("Неполных записей: %1$ld. %2$@", result.incompleteTraces, status)
    }

    private static func format(_ value: TimeInterval?) -> String {
        guard let value else { return "—" }
        if value < 60 { return L10n.format("%.0f с", value) }
        let minutes = Int(value) / 60
        let seconds = Int(value) % 60
        return L10n.format("%1$ld мин %2$ld с", minutes, seconds)
    }
}
