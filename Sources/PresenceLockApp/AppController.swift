import AppKit
import Foundation
import PresenceLockCore

final class AppController: NSObject, NSMenuDelegate {
    private struct FeedbackTarget {
        let id: UUID
        let timestamp: Date
        let idleSeconds: TimeInterval
    }

    private struct LastFeedbackAction {
        enum Kind {
            case prediction(PredictionLabel)
            case episode(IdleEpisodeLabel)
        }

        let target: FeedbackTarget
        let feedbackTimestamp: Date
        let kind: Kind
    }

    private let preferences: PresenceLockPreferences
    private var configuration: DetectionConfiguration
    private let idleMonitor = InputIdleMonitor()
    private let camera = CameraPresenceDetector()
    private let lockExecutor = ScreenLockExecutor()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private lazy var warningPanel: WarningPanelController = {
        let controller = WarningPanelController()
        controller.onPresent = { [weak self] in self?.acknowledgePresence() }
        controller.onPause = { [weak self] in self?.pauseThirtyMinutes() }
        return controller
    }()
    private lazy var settingsWindow = PresenceLockSettingsWindowController(
        preferences: preferences,
        onSave: { [weak self] configuration in
            self?.applyConfiguration(configuration)
        }
    )
    private var cameraPreview: CameraPreviewWindowController?
    private var previewOpenedSinceTick = false
    private var quietEpisodeUsedPreview = false

    private var stateMachine: PresenceStateMachine
    private var eventStore: JSONLEventStore?
    private var timer: Timer?
    private var monitoringEnabled = false
    private var cameraAuthorizationPending = false
    private var pauseUntil: Date?
    private var currentIdle: TimeInterval = 0
    private var currentReading = PresenceReading.unknown()
    private var previousIdle: TimeInterval?
    private var previousTickUptime: TimeInterval?
    private var episodeClosedForCurrentIdle = false
    private var needsInputAnchor = true
    private var replayQuietEpisodeStarted = false
    private var quietEpisodeHasObservedStart = false
    private var cameraRetryAfter: Date?
    private var latestPrediction: (target: FeedbackTarget, label: PredictionLabel?)?
    private var latestEpisode: (target: FeedbackTarget, label: IdleEpisodeLabel?)?
    private var lastFeedbackAction: LastFeedbackAction?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var workspaceSession = WorkspaceSessionState()
    private var sessionActive = false
    private var storageErrorMessage: String?
    private var lastLockFailure: String?
    private var latestLockRequest: UUID?
    private var journalGeneration = UUID()
    private var reportInFlight: UUID?
    private var statusMessage = "Мониторинг не запущен"

    private let statusMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let detailMenuItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let lockErrorItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let reportItem = NSMenuItem(title: "Сформировать отчёт", action: nil, keyEquivalent: "")
    private let toggleMonitoringItem = NSMenuItem(title: "Начать обучение", action: nil, keyEquivalent: "")
    private let learningModeItem = NSMenuItem(title: "Режим обучения", action: nil, keyEquivalent: "")
    private let shadowModeItem = NSMenuItem(title: "Теневой режим", action: nil, keyEquivalent: "")
    private let armedModeItem = NSMenuItem(title: "Боевая блокировка…", action: nil, keyEquivalent: "")
    private let settingsItem = NSMenuItem(title: "Настроить пороги…", action: nil, keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Запускать при входе", action: nil, keyEquivalent: "")
    private let feedbackMenu = NSMenu(title: "Уточнить наблюдение")
    private let episodeHeading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let predictionHeading = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let confirmDepartureItem = NSMenuItem(title: "К этому моменту я уже отошёл", action: nil, keyEquivalent: "")
    private let markFalseAlarmItem = NSMenuItem(title: "В этот момент я был у экрана", action: nil, keyEquivalent: "")
    private let episodeDepartureItem = NSMenuItem(title: "Я отходил", action: nil, keyEquivalent: "")
    private let episodePresentItem = NSMenuItem(title: "Всё время был у экрана", action: nil, keyEquivalent: "")
    private let correctLastFeedbackItem = NSMenuItem(title: "Исправить последнюю метку…", action: nil, keyEquivalent: "")

    override init() {
        let preferences = PresenceLockPreferences()
        let configuration = preferences.loadConfiguration()
        self.preferences = preferences
        self.configuration = configuration
        stateMachine = PresenceStateMachine(mode: .learning, configuration: configuration)
        super.init()
        monitoringEnabled = preferences.loadMonitoringEnabled() && camera.isAuthorized
        if monitoringEnabled {
            statusMessage = "Мониторинг восстановлен · режим обучения"
        } else if preferences.loadMonitoringEnabled() {
            statusMessage = "Мониторинг ждёт доступа к камере"
        }
        eventStore = try? JSONLEventStore(directoryURL: Self.dataDirectory())
        if eventStore == nil {
            storageErrorMessage = "Журнал недоступен"
        }
        do {
            try eventStore?.purgeFiles(olderThanDays: 21)
            restoreLatestFeedback()
        } catch {
            storageErrorMessage = "Ошибка чтения журнала"
        }
        camera.onHardFailure = { [weak self] in
            self?.cameraRetryAfter = Date().addingTimeInterval(30)
            self?.closeEpisodeForBoundary()
            self?.resetForBoundary(message: "Камера недоступна")
        }
        observeWorkspaceBoundaries()
        sessionActive = WorkspaceSessionState.consoleIsUsable
        configureMenu()
    }

    deinit {
        workspaceObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }

    func start() {
        timer = Timer.scheduledTimer(
            timeInterval: 1,
            target: self,
            selector: #selector(tick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(timer!, forMode: .common)
        restoreMonitoringIfNeeded()
        updateMenu()
    }

    func stop() {
        closeEpisodeForBoundary()
        timer?.invalidate()
        camera.poseShadowEnabled = false
        camera.stop()
        cameraPreview?.onClose = nil
        cameraPreview?.close()
        warningPanel.hide()
        settingsWindow.close()
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === feedbackMenu {
            updateFeedbackMenu()
        } else {
            updateMenu()
        }
    }

    @objc private func tick() {
        let now = Date()
        if monitoringEnabled { refreshSessionActivity() }
        let cameraSnapshot = camera.decisionSnapshot()
        let monotonicNow = cameraSnapshot.monotonicTime
        let previewAffectedTick = previewOpenedSinceTick || cameraPreview?.isVisible == true
        previewOpenedSinceTick = false
        defer { updateCameraPreviewStatus(now: now, monotonicNow: monotonicNow) }
        guard monitoringEnabled, sessionActive, pauseUntil.map({ $0 <= now }) ?? true else {
            camera.poseShadowEnabled = false
            camera.stop()
            warningPanel.hide()
            if !monitoringEnabled {
                statusMessage = cameraAuthorizationPending ? "Мониторинг ждёт доступа к камере" : "Мониторинг не запущен"
            } else if !sessionActive {
                statusMessage = "Сессия неактивна"
            } else if let pauseUntil {
                statusMessage = "Пауза до \(Self.timeFormatter.string(from: pauseUntil))"
            }
            updateMenu()
            return
        }
        self.pauseUntil = nil
        guard let idle = idleMonitor.secondsSinceLastInput() else {
            if previousTickUptime != nil { closeEpisodeForBoundary(now: now) }
            camera.stop()
            resetForBoundary(message: "Нет данных об активности клавиатуры и мыши")
            updateMenu()
            return
        }
        currentIdle = idle
        let idleBeforeInput = previousIdle
        let updateGap = previousTickUptime.map { monotonicNow - $0 } ?? 0
        let inputOccurred = idleBeforeInput.map {
            InputIdleMonitor.inputResumed(previousIdle: $0, currentIdle: currentIdle, elapsed: updateGap)
        } ?? false
        let updateWasInterrupted = updateGap > configuration.maximumUpdateGapSeconds
        if updateWasInterrupted {
            closeEpisodeForBoundary(now: now)
            replayQuietEpisodeStarted = false
            quietEpisodeHasObservedStart = false
            needsInputAnchor = true
        }
        previousIdle = currentIdle
        previousTickUptime = monotonicNow
        let previewVisible = cameraPreview?.isVisible == true
        updateCameraCapture(now: now, idleSeconds: currentIdle, previewVisible: previewVisible)

        // The preview has its own results. Below the normal probe threshold, the
        // learning log still sees the same lack of a camera check as ordinary use.
        let previewOnly = previewVisible && currentIdle < configuration.probeIdleSeconds
        currentReading = previewOnly
            ? .unknown(at: now, monotonic: monotonicNow)
            : cameraSnapshot.reading
        let cameraEvidence: CameraTickEvidence = previewOnly ? .none : cameraSnapshot.evidence
        let isQuietTick = !inputOccurred && currentIdle >= 1
        let startsQuietEpisode = isQuietTick && !replayQuietEpisodeStarted
        if startsQuietEpisode {
            quietEpisodeUsedPreview = previewAffectedTick
            quietEpisodeHasObservedStart = !updateWasInterrupted
                && !episodeClosedForCurrentIdle
                && stateMachine.state == .active
        } else if previewAffectedTick {
            quietEpisodeUsedPreview = true
        }
        let actions = stateMachine.update(StateMachineInput(
            now: now,
            monotonicNow: monotonicNow,
            idleSeconds: currentIdle,
            inputOccurred: inputOccurred,
            updateGapSeconds: updateGap,
            reading: currentReading,
            sessionActive: sessionActive,
            cameraEvidence: cameraEvidence
        ))

        // Pose is observational: its output never enters StateMachineInput or the lock executor.
        let ordinaryQuietProbe = !stateMachine.mode.performsRealLock
            && quietEpisodeHasObservedStart && !quietEpisodeUsedPreview
            && !updateWasInterrupted && !inputOccurred && currentIdle >= configuration.probeIdleSeconds
            && (cameraRetryAfter.map { $0 <= now } ?? true)
        let poseWasEnabled = camera.poseShadowEnabled
        let confirming = stateMachine.state == .suspectedAway || stateMachine.state == .warning
        camera.poseShadowEnabled = ordinaryQuietProbe && confirming
        let poseShadow = cameraSnapshot.poseShadow.flatMap { sample -> PoseShadowSample? in
            let age = monotonicNow - sample.capturedAtMonotonic
            guard ordinaryQuietProbe, poseWasEnabled, currentReading.observation == .absent,
                  currentReading.cameraAvailable, !cameraEvidence.sawUncertainty, !cameraEvidence.sawPresence,
                  currentReading.capturedAtMonotonic >= sample.capturedAtMonotonic,
                  age >= 0, age <= configuration.maximumSampleAgeSeconds else { return nil }
            return sample
        }

        var replayTick: DecisionReplayTick? = DecisionReplayTick(
            monotonicTime: monotonicNow,
            updateGapSeconds: updateGap,
            idleSeconds: currentIdle,
            inputOccurred: inputOccurred,
            configuration: startsQuietEpisode ? configuration : nil,
            cameraPreviewActive: previewAffectedTick ? true : nil,
            cameraEvidence: cameraEvidence,
            poseShadow: poseShadow
        )
        @discardableResult
        func appendTick(id: UUID = UUID(), event: String?, idleSeconds: TimeInterval? = nil) -> Bool {
            let saved = appendRecord(id: id, now: now, event: event, idleSeconds: idleSeconds, replayTick: replayTick)
            if saved { replayTick = nil }
            return saved
        }

        if startsQuietEpisode {
            replayQuietEpisodeStarted = appendTick(event: quietEpisodeHasObservedStart
                ? "idleStarted"
                : "idleUnanchored")
        }
        if inputOccurred {
            if episodeClosedForCurrentIdle || !quietEpisodeHasObservedStart || updateWasInterrupted {
                needsInputAnchor = !appendTick(event: "inputAnchor", idleSeconds: 0)
            } else {
                let episodeID = UUID()
                let episodeIdle = max(idleBeforeInput ?? 0, currentIdle)
                if appendTick(
                    id: episodeID,
                    event: "inputResumed",
                    idleSeconds: episodeIdle
                ) {
                    if episodeIdle >= configuration.probeIdleSeconds {
                        latestEpisode = (FeedbackTarget(
                            id: episodeID,
                            timestamp: now,
                            idleSeconds: episodeIdle
                        ), nil)
                    }
                    needsInputAnchor = false
                }
            }
            episodeClosedForCurrentIdle = false
            replayQuietEpisodeStarted = false
            quietEpisodeHasObservedStart = false
        } else if currentIdle < 1 {
            episodeClosedForCurrentIdle = false
            if needsInputAnchor || replayQuietEpisodeStarted {
                needsInputAnchor = !appendTick(event: "inputAnchor", idleSeconds: 0)
            }
            replayQuietEpisodeStarted = false
            quietEpisodeHasObservedStart = false
        }
        var immediateStatusMessage: String?
        for action in actions {
            switch action {
            case .warningStarted:
                appendTick(event: "warningStarted")
                if let deadline = stateMachine.warningDeadlineMonotonic {
                    warningPanel.show(
                        deadlineMonotonic: deadline,
                        performsRealLock: stateMachine.mode.performsRealLock
                    )
                }
            case .warningCancelled:
                warningPanel.hide()
                appendTick(event: "warningCancelled")
            case .wouldLock:
                warningPanel.hide()
                let id = UUID()
                if appendTick(id: id, event: "wouldLock") {
                    latestPrediction = (FeedbackTarget(
                        id: id,
                        timestamp: now,
                        idleSeconds: currentIdle
                    ), nil)
                }
            case .lock:
                warningPanel.hide()
                let id = UUID()
                if appendTick(id: id, event: "lock") {
                    latestPrediction = (FeedbackTarget(
                        id: id,
                        timestamp: now,
                        idleSeconds: currentIdle
                    ), nil)
                    // Persist the decision before asking macOS to lock, then recheck
                    // input and camera evidence in case they changed during that write.
                    guard lockStillSupported(at: monotonicNow, confirmedReading: currentReading) else {
                        let skippedAt = Date()
                        _ = appendRecord(now: skippedAt, event: "lockSuppressed", lockDecisionID: id)
                        closeEpisodeForBoundary(now: skippedAt)
                        resetForBoundary(message: "Блокировка отменена · новые данные")
                        immediateStatusMessage = statusMessage
                        continue
                    }
                    let generation = journalGeneration
                    latestLockRequest = id
                    lastLockFailure = nil
                    lockExecutor.requestLock { [weak self] result in
                        guard let self, self.journalGeneration == generation else { return }
                        let event: String
                        switch result {
                        case .requested:
                            event = "lockRequestAccepted"
                        case let .failed(message):
                            event = "lockFailed"
                            if self.latestLockRequest == id {
                                self.lastLockFailure = "Последний запрос блокировки не выполнен · \(message)"
                            }
                        }
                        _ = self.appendRecord(now: Date(), event: event, lockDecisionID: id)
                        self.updateMenu()
                    }
                }
            case let .stateChanged(_, to):
                if to != .warning { warningPanel.hide() }
            }
        }

        if isQuietTick, !startsQuietEpisode, replayTick != nil {
            appendTick(event: nil)
        }

        if let immediateStatusMessage {
            statusMessage = immediateStatusMessage
        } else if let retry = cameraRetryAfter, retry > now {
            statusMessage = storageErrorMessage
                ?? "Камера: повтор в \(max(1, Int(retry.timeIntervalSince(now)))) с"
        } else {
            statusMessage = storageErrorMessage ?? Self.label(for: stateMachine.state)
        }
        updateMenu()
    }

    private func lockStillSupported(at decisionTime: TimeInterval, confirmedReading: PresenceReading) -> Bool {
        guard monitoringEnabled, sessionActive, stateMachine.mode == .armed,
              WorkspaceSessionState.consoleIsUsable, let latestIdle = idleMonitor.secondsSinceLastInput()
        else { return false }
        let latest = camera.decisionSnapshot(consumeEvidence: false)
        let age = latest.monotonicTime - latest.reading.capturedAtMonotonic
        let expectedIdle = currentIdle + (latest.monotonicTime - decisionTime)
        return latestIdle >= configuration.probeIdleSeconds
            && latestIdle + 0.25 >= expectedIdle
            && latest.reading.cameraAvailable
            && latest.reading.observation == .absent
            && latest.reading.capturedAtMonotonic >= confirmedReading.capturedAtMonotonic
            && age >= 0 && age <= configuration.maximumSampleAgeSeconds
            && !latest.evidence.sawPresence && !latest.evidence.sawUncertainty
    }

    @objc private func toggleMonitoring() {
        guard !cameraAuthorizationPending else { return }

        if monitoringEnabled {
            closeEpisodeForBoundary()
            monitoringEnabled = false
            preferences.saveMonitoringEnabled(false)
            camera.stop()
            warningPanel.hide()
            resetForBoundary(message: "Мониторинг остановлен")
            updateMenu()
            return
        }

        requestMonitoringAuthorization(openSettingsOnFailure: true)
    }

    private func restoreMonitoringIfNeeded() {
        guard preferences.loadMonitoringEnabled(), !monitoringEnabled else { return }
        requestMonitoringAuthorization(openSettingsOnFailure: false)
    }

    private func requestMonitoringAuthorization(openSettingsOnFailure: Bool) {
        guard !cameraAuthorizationPending else { return }
        cameraAuthorizationPending = true
        statusMessage = "Мониторинг ждёт доступа к камере"
        updateMenu()

        camera.requestAuthorization { [weak self] granted in
            guard let self else { return }
            self.cameraAuthorizationPending = false
            self.monitoringEnabled = granted
            self.preferences.saveMonitoringEnabled(granted)
            self.statusMessage = granted ? "Мониторинг запущен" : "Нет доступа к камере"
            self.previousIdle = nil
            self.previousTickUptime = nil
            self.episodeClosedForCurrentIdle = false
            self.needsInputAnchor = true
            self.replayQuietEpisodeStarted = false
            self.quietEpisodeHasObservedStart = false
            self.cameraRetryAfter = nil
            self.camera.poseShadowEnabled = false
            self.camera.resetDecisionEvidence()
            _ = self.stateMachine.resetSession()
            self.updateMenu()
            if !granted, openSettingsOnFailure {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!)
            }
        }
    }

    @objc private func selectLearningMode() {
        guard stateMachine.mode != .learning else { return }
        closeEpisodeForBoundary()
        warningPanel.hide()
        _ = stateMachine.setMode(.learning)
        resetForBoundary(message: "Режим обучения")
        updateMenu()
    }

    @objc private func selectShadowMode() {
        guard stateMachine.mode != .shadow else { return }
        closeEpisodeForBoundary()
        warningPanel.hide()
        _ = stateMachine.setMode(.shadow)
        resetForBoundary(message: "Теневой режим")
        updateMenu()
    }

    @objc private func selectArmedMode() {
        guard stateMachine.mode != .armed else {
            selectShadowMode()
            return
        }

        let alert = NSAlert()
        alert.messageText = "Включить реальную блокировку?"
        alert.informativeText = "После \(Self.shortDuration(configuration.probeIdleSeconds)) без ввода "
            + "PresenceLock включит камеру. Если человек не обнаружен \(Self.shortDuration(configuration.absenceConfirmationSeconds)), "
            + "появится предупреждение на \(Self.shortDuration(configuration.warningSeconds)). "
            + "Если свежий кадр подтвердит отсутствие, PresenceLock отправит macOS запрос на блокировку.\n\n"
            + "Перед включением проверьте в системных настройках «Экран блокировки», что пароль запрашивается сразу после запуска заставки "
            + "или выключения дисплея. Режим действует до завершения PresenceLock."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Включить боевой режим")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        closeEpisodeForBoundary()
        warningPanel.hide()
        _ = stateMachine.setMode(.armed)
        resetForBoundary(message: "Боевая блокировка включена")
        updateMenu()
    }

    @objc private func openSettings() {
        settingsWindow.show(configuration: configuration)
    }

    @objc func openCameraPreview() {
        previewOpenedSinceTick = true
        camera.poseShadowEnabled = false
        if let cameraPreview {
            cameraPreview.show()
            return
        }

        let preview = CameraPreviewWindowController()
        preview.onClose = { [weak self] in
            guard let self else { return }
            self.camera.setDiagnosticObservationHandler(nil)
            self.camera.setDiagnosticPreviewLayer(nil)
            self.cameraPreview = nil
            guard let idle = self.idleMonitor.secondsSinceLastInput() else {
                self.camera.stop()
                return
            }
            self.updateCameraCapture(
                now: Date(),
                idleSeconds: idle,
                previewVisible: false
            )
        }
        cameraPreview = preview
        camera.setDiagnosticPreviewLayer(preview.videoPreviewLayer)
        preview.show()
        updateCameraPreviewStatus(now: Date(), monotonicNow: ProcessInfo.processInfo.systemUptime)
        camera.setDiagnosticObservationHandler { [weak preview] observation in
            preview?.display(observation)
        }
    }

    private func updateCameraPreviewStatus(now: Date, monotonicNow: TimeInterval) {
        guard let cameraPreview else { return }
        if cameraAuthorizationPending {
            cameraPreview.setWaiting("Ожидаю разрешения на доступ к камере")
        } else if !monitoringEnabled {
            cameraPreview.setWaiting("Включите мониторинг в меню щита PresenceLock")
        } else if !sessionActive {
            cameraPreview.setWaiting("Камера выключена, пока сессия Mac неактивна")
        } else if let pauseUntil, pauseUntil > now {
            cameraPreview.setWaiting("Мониторинг на паузе")
        } else if let cameraRetryAfter, cameraRetryAfter > now {
            cameraPreview.setWaiting("Камера временно недоступна")
        } else if !camera.isRunning {
            cameraPreview.setWaiting("Камера запускается…")
        } else if let lastObservation = cameraPreview.lastFrameUptime,
                  monotonicNow - lastObservation <= configuration.maximumSampleAgeSeconds {
            cameraPreview.refreshVideoStatus()
        } else {
            cameraPreview.setWaiting("Жду результат распознавания…", showVideo: true)
        }
    }

    private func updateCameraCapture(now: Date, idleSeconds: TimeInterval, previewVisible: Bool) {
        let normalProbeDue = idleSeconds >= configuration.probeIdleSeconds
        guard monitoringEnabled, sessionActive,
              pauseUntil.map({ $0 <= now }) ?? true,
              cameraRetryAfter.map({ $0 <= now }) ?? true,
              normalProbeDue || previewVisible else {
            camera.stop()
            return
        }

        let confirmingDeparture = stateMachine.state == .suspectedAway || stateMachine.state == .warning
        camera.processingInterval = normalProbeDue && confirmingDeparture ? 0.5 : configuration.sampleIntervalSeconds
        camera.start()
    }

    @objc private func toggleLaunchAtLogin() {
        if LoginItemManager.requiresApproval {
            LoginItemManager.openApprovalSettings()
            statusMessage = "Открыты настройки автозапуска"
            updateMenu()
            return
        }

        let shouldEnable = !LoginItemManager.isRegistered
        if shouldEnable,
           !Bundle.main.bundleURL.path.hasPrefix("/Applications/") {
            showError("Сначала переместите PresenceLock.app в папку «Программы». После этого автозапуск можно будет включить.")
            return
        }

        do {
            try LoginItemManager.setEnabled(shouldEnable)
            if LoginItemManager.requiresApproval {
                statusMessage = "Разрешите автозапуск в Настройках системы"
            }
        } catch {
            showError("Не удалось изменить автозапуск: \(error.localizedDescription)")
        }
        updateMenu()
    }

    private func acknowledgePresence() {
        camera.poseShadowEnabled = false
        let actions = stateMachine.acknowledgePresence()
        if actions.contains(.warningCancelled) {
            _ = appendRecord(now: Date(), event: "warningAcknowledged")
        }
        warningPanel.hide()
        cameraRetryAfter = nil
        statusMessage = "Вы здесь"
        updateMenu()
    }

    private func applyConfiguration(_ newConfiguration: DetectionConfiguration) {
        closeEpisodeForBoundary()
        warningPanel.hide()
        // New thresholds have not passed the shadow validation that justified the previous
        // armed choice. Demote to shadow instead of silently applying an untested real-lock
        // policy.
        let wasArmed = stateMachine.mode == .armed
        let mode: MonitoringMode = wasArmed ? .shadow : stateMachine.mode
        preferences.save(newConfiguration)
        configuration = newConfiguration
        stateMachine = PresenceStateMachine(mode: mode, configuration: newConfiguration)
        camera.poseShadowEnabled = false
        camera.resetDecisionEvidence()
        previousIdle = nil
        previousTickUptime = nil
        needsInputAnchor = true
        replayQuietEpisodeStarted = false
        quietEpisodeHasObservedStart = false
        currentReading = .unknown()
        statusMessage = wasArmed
            ? "Пороги обновлены · боевая блокировка выключена"
            : "Пороги обновлены"
        updateMenu()
    }

    @objc private func pauseThirtyMinutes() {
        closeEpisodeForBoundary()
        pauseUntil = Date().addingTimeInterval(30 * 60)
        camera.stop()
        warningPanel.hide()
        resetForBoundary(message: "Мониторинг приостановлен")
        updateMenu()
    }

    @objc private func resumeNow() {
        guard pauseUntil != nil else { return }
        closeEpisodeForBoundary()
        pauseUntil = nil
        cameraRetryAfter = nil
        resetForBoundary(message: "Мониторинг продолжен")
        updateMenu()
    }

    @objc private func confirmDeparture(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FeedbackTarget else { return }
        savePredictionFeedback(.confirmedDeparture, for: target)
    }

    @objc private func markFalseAlarm(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FeedbackTarget else { return }
        savePredictionFeedback(.falseAlarm, for: target)
    }

    @objc private func markEpisodeDeparture(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FeedbackTarget else { return }
        saveEpisodeFeedback(.departed, for: target)
    }

    @objc private func markEpisodePresent(_ sender: NSMenuItem) {
        guard let target = sender.representedObject as? FeedbackTarget else { return }
        saveEpisodeFeedback(.stayedPresent, for: target)
    }

    @objc private func correctLastFeedback() {
        guard let lastFeedbackAction else { return }
        let alert = NSAlert()
        alert.messageText = "Исправить последнюю метку?"
        alert.informativeText = "Текущая метка будет заменена противоположной. В журнале сохранится история исправления."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Исправить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        switch lastFeedbackAction.kind {
        case let .prediction(label):
            savePredictionFeedback(label == .confirmedDeparture ? .falseAlarm : .confirmedDeparture,
                                   for: lastFeedbackAction.target)
        case let .episode(label):
            saveEpisodeFeedback(label == .departed ? .stayedPresent : .departed,
                                for: lastFeedbackAction.target)
        }
    }

    @objc private func openDataFolder() {
        NSWorkspace.shared.open(Self.dataDirectory())
    }

    @objc private func exportSummary() {
        guard let eventStore, reportInFlight == nil else { return }
        let generation = journalGeneration
        let settings = configuration
        reportInFlight = generation
        reportItem.title = "Готовлю отчёт…"
        reportItem.isEnabled = false
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { try LearningReport.make(store: eventStore, configuration: settings) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.reportInFlight == generation else { return }
                self.reportInFlight = nil
                self.reportItem.title = "Сформировать отчёт"
                self.reportItem.isEnabled = true
                do {
                    let url = eventStore.directoryURL.appendingPathComponent("learning-summary.md")
                    try result.get().write(to: url, atomically: true, encoding: .utf8)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } catch {
                    self.showError("Не удалось сформировать отчёт: \(error.localizedDescription)")
                }
            }
        }
    }

    @objc private func deleteAllData() {
        let alert = NSAlert()
        alert.messageText = "Удалить все локальные данные обучения?"
        alert.informativeText = "Удаление необратимо. Кадров и нажатий клавиш в журнале нет."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Удалить")
        alert.addButton(withTitle: "Отмена")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            journalGeneration = UUID()
            reportInFlight = nil
            reportItem.title = "Сформировать отчёт"
            reportItem.isEnabled = true
            latestLockRequest = nil
            lastLockFailure = nil
            camera.poseShadowEnabled = false
            try eventStore?.deleteAll()
            replayQuietEpisodeStarted = false
            quietEpisodeHasObservedStart = false
            needsInputAnchor = true
            latestPrediction = nil
            latestEpisode = nil
            lastFeedbackAction = nil
            updateMenu()
        } catch {
            showError("Не удалось удалить данные: \(error.localizedDescription)")
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureMenu() {
        if let button = statusItem.button {
            button.toolTip = "PresenceLock"
            if let iconURL = Bundle.main.url(forResource: "StatusIcon", withExtension: "png"),
               let icon = NSImage(contentsOf: iconURL) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
                button.imagePosition = .imageOnly
                button.title = ""
            } else {
                button.title = "◉"
            }
        }

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusMenuItem.isEnabled = false
        detailMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(detailMenuItem)
        lockErrorItem.isEnabled = false
        menu.addItem(lockErrorItem)
        menu.addItem(.separator())

        toggleMonitoringItem.target = self
        toggleMonitoringItem.action = #selector(toggleMonitoring)
        menu.addItem(toggleMonitoringItem)
        let cameraPreviewItem = NSMenuItem(
            title: "Проверить камеру…",
            action: #selector(openCameraPreview),
            keyEquivalent: ""
        )
        cameraPreviewItem.target = self
        menu.addItem(cameraPreviewItem)

        learningModeItem.target = self
        learningModeItem.action = #selector(selectLearningMode)
        shadowModeItem.target = self
        shadowModeItem.action = #selector(selectShadowMode)
        armedModeItem.target = self
        armedModeItem.action = #selector(selectArmedMode)
        menu.addItem(learningModeItem)
        menu.addItem(shadowModeItem)
        menu.addItem(armedModeItem)
        menu.addItem(.separator())

        settingsItem.target = self
        settingsItem.action = #selector(openSettings)
        launchAtLoginItem.target = self
        launchAtLoginItem.action = #selector(toggleLaunchAtLogin)
        menu.addItem(settingsItem)
        menu.addItem(launchAtLoginItem)

        let pause = NSMenuItem(title: "Пауза на 30 минут", action: #selector(pauseThirtyMinutes), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        let resume = NSMenuItem(title: "Продолжить сейчас", action: #selector(resumeNow), keyEquivalent: "")
        resume.target = self
        menu.addItem(resume)
        menu.addItem(.separator())

        feedbackMenu.delegate = self
        feedbackMenu.autoenablesItems = false
        episodeHeading.isEnabled = false
        feedbackMenu.addItem(episodeHeading)
        episodeDepartureItem.target = self
        episodeDepartureItem.action = #selector(markEpisodeDeparture(_:))
        episodePresentItem.target = self
        episodePresentItem.action = #selector(markEpisodePresent(_:))
        feedbackMenu.addItem(episodePresentItem)
        feedbackMenu.addItem(episodeDepartureItem)
        feedbackMenu.addItem(.separator())
        predictionHeading.isEnabled = false
        feedbackMenu.addItem(predictionHeading)
        confirmDepartureItem.target = self
        confirmDepartureItem.action = #selector(confirmDeparture(_:))
        markFalseAlarmItem.target = self
        markFalseAlarmItem.action = #selector(markFalseAlarm(_:))
        feedbackMenu.addItem(confirmDepartureItem)
        feedbackMenu.addItem(markFalseAlarmItem)
        feedbackMenu.addItem(.separator())
        correctLastFeedbackItem.target = self
        correctLastFeedbackItem.action = #selector(correctLastFeedback)
        feedbackMenu.addItem(correctLastFeedbackItem)
        let feedbackItem = menu.addItem(withTitle: feedbackMenu.title, action: nil, keyEquivalent: "")
        feedbackItem.submenu = feedbackMenu

        reportItem.action = #selector(exportSummary)
        reportItem.target = self
        menu.addItem(reportItem)
        let folder = NSMenuItem(title: "Открыть папку данных", action: #selector(openDataFolder), keyEquivalent: "")
        folder.target = self
        menu.addItem(folder)
        let delete = NSMenuItem(title: "Удалить все данные…", action: #selector(deleteAllData), keyEquivalent: "")
        delete.target = self
        menu.addItem(delete)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Завершить PresenceLock", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
    }

    private func updateMenu() {
        statusMenuItem.title = "PresenceLock · \(statusMessage)"
        lockErrorItem.isHidden = lastLockFailure == nil
        lockErrorItem.title = lastLockFailure ?? ""
        let idleText = previousIdle.map { "\(Int($0)) с" } ?? "—"
        detailMenuItem.title = "Без ввода: \(idleText) · Камера: \(camera.isRunning ? "включена" : "выключена")"
        if cameraAuthorizationPending {
            toggleMonitoringItem.title = "Ожидаю доступ к камере…"
            toggleMonitoringItem.isEnabled = false
        } else {
            toggleMonitoringItem.title = monitoringEnabled ? "Остановить мониторинг" : "Начать мониторинг"
            toggleMonitoringItem.isEnabled = true
        }
        learningModeItem.state = stateMachine.mode == .learning ? .on : .off
        shadowModeItem.state = stateMachine.mode == .shadow ? .on : .off
        armedModeItem.state = stateMachine.mode == .armed ? .on : .off
        armedModeItem.title = stateMachine.mode == .armed
            ? "Выключить боевую блокировку"
            : "Боевая блокировка…"
        if LoginItemManager.requiresApproval {
            launchAtLoginItem.state = .mixed
            launchAtLoginItem.title = "Автозапуск: требуется разрешение…"
        } else {
            launchAtLoginItem.state = LoginItemManager.isEnabled ? .on : .off
            launchAtLoginItem.title = "Запускать при входе"
        }
        switch stateMachine.state {
        case .presentQuiet, .active:
            statusItem.button?.contentTintColor = .systemGreen
        case .suspectedAway, .warning:
            statusItem.button?.contentTintColor = .systemOrange
        case .unknown:
            statusItem.button?.contentTintColor = .systemRed
        default:
            statusItem.button?.contentTintColor = nil
        }
    }

    // Bind actions to the observations shown when the user opened the submenu.
    // A monitoring tick can complete a different episode while the menu is tracking.
    private func updateFeedbackMenu() {
        episodeHeading.title = latestEpisode.map {
            "Последняя пауза · до \(Self.targetDate($0.target.timestamp)) · \(Self.shortDuration($0.target.idleSeconds))"
        } ?? "Пока нет завершённых пауз"
        predictionHeading.title = latestPrediction.map {
            "Последний прогноз · \(Self.targetDate($0.target.timestamp))"
        } ?? "Пока нет прогнозов"
        for item in [episodePresentItem, episodeDepartureItem] {
            item.representedObject = latestEpisode?.target
            item.isEnabled = latestEpisode != nil
        }
        for item in [confirmDepartureItem, markFalseAlarmItem] {
            item.representedObject = latestPrediction?.target
            item.isEnabled = latestPrediction != nil
        }
        episodePresentItem.state = latestEpisode?.label == .stayedPresent ? .on : .off
        episodeDepartureItem.state = latestEpisode?.label == .departed ? .on : .off
        confirmDepartureItem.state = latestPrediction?.label == .confirmedDeparture ? .on : .off
        markFalseAlarmItem.state = latestPrediction?.label == .falseAlarm ? .on : .off
        correctLastFeedbackItem.title = lastFeedbackAction.map {
            "Исправить последнюю отметку · \(Self.targetDate($0.target.timestamp))…"
        } ?? "Исправить последнюю отметку…"
        correctLastFeedbackItem.isEnabled = lastFeedbackAction != nil
    }

    @discardableResult
    private func appendRecord(
        id: UUID = UUID(),
        now: Date,
        event: String?,
        idleSeconds: TimeInterval? = nil,
        lockDecisionID: UUID? = nil,
        replayTick: DecisionReplayTick? = nil
    ) -> Bool {
        var record = ObservationRecord(
            id: id,
            timestamp: now,
            idleSeconds: idleSeconds ?? currentIdle,
            observation: currentReading.observation,
            confidence: currentReading.confidence,
            cameraAvailable: currentReading.cameraAvailable,
            readingAgeSeconds: (replayTick?.monotonicTime ?? ProcessInfo.processInfo.systemUptime)
                - currentReading.capturedAtMonotonic,
            state: stateMachine.state,
            mode: stateMachine.mode,
            event: event,
            replayTick: replayTick
        )
        record.lockDecisionID = lockDecisionID
        guard let eventStore else {
            storageErrorMessage = "Журнал недоступен"
            return false
        }
        do {
            try eventStore.append(record)
            storageErrorMessage = nil
            return true
        } catch {
            storageErrorMessage = "Ошибка записи журнала"
            return false
        }
    }

    private func savePredictionFeedback(_ label: PredictionLabel, for prediction: FeedbackTarget) {
        guard let eventStore else { return }
        if latestPrediction?.target.id == prediction.id, latestPrediction?.label == label { return }
        let timestamp = Date()
        do {
            try eventStore.append(PredictionFeedback(
                predictionID: prediction.id,
                timestamp: timestamp,
                label: label
            ))
            if latestPrediction?.target.id == prediction.id { latestPrediction?.label = label }
            lastFeedbackAction = LastFeedbackAction(
                target: prediction,
                feedbackTimestamp: timestamp,
                kind: .prediction(label)
            )
            storageErrorMessage = nil
            updateMenu()
        } catch {
            showError("Не удалось сохранить оценку прогноза.")
        }
    }

    private func saveEpisodeFeedback(_ label: IdleEpisodeLabel, for episode: FeedbackTarget) {
        guard let eventStore else { return }
        if latestEpisode?.target.id == episode.id, latestEpisode?.label == label { return }
        let timestamp = Date()
        do {
            try eventStore.append(IdleEpisodeFeedback(
                episodeID: episode.id,
                timestamp: timestamp,
                label: label
            ))
            if latestEpisode?.target.id == episode.id { latestEpisode?.label = label }
            lastFeedbackAction = LastFeedbackAction(
                target: episode,
                feedbackTimestamp: timestamp,
                kind: .episode(label)
            )
            storageErrorMessage = nil
            updateMenu()
        } catch {
            showError("Не удалось сохранить оценку паузы.")
        }
    }

    private func restoreLatestFeedback() {
        guard let eventStore else { return }
        do {
            let records = try eventStore.loadObservationRecords()
            let predictionFeedback = try eventStore.loadFeedback()
            let episodeFeedback = try eventStore.loadEpisodeFeedback()
            var probeIdleSeconds = configuration.probeIdleSeconds
            var latestEpisodeRecord: ObservationRecord?
            for record in records {
                if let saved = record.replayTick?.configuration {
                    probeIdleSeconds = saved.probeIdleSeconds
                }
                if record.event == "episodeBoundary"
                    || (record.event == "inputResumed" && record.idleSeconds >= probeIdleSeconds) {
                    latestEpisodeRecord = record
                }
            }
            func target(_ record: ObservationRecord) -> FeedbackTarget {
                FeedbackTarget(id: record.id, timestamp: record.timestamp, idleSeconds: record.idleSeconds)
            }
            if let record = latestEpisodeRecord {
                latestEpisode = (target(record), episodeFeedback.last { $0.episodeID == record.id }?.label)
            }
            if let record = records.last(where: { $0.event == "wouldLock" || $0.event == "lock" }) {
                latestPrediction = (target(record), predictionFeedback.last { $0.predictionID == record.id }?.label)
            }
            if let feedback = predictionFeedback.last,
               let record = records.last(where: { $0.id == feedback.predictionID }) {
                lastFeedbackAction = LastFeedbackAction(target: target(record), feedbackTimestamp: feedback.timestamp,
                                                        kind: .prediction(feedback.label))
            }
            if let feedback = episodeFeedback.last,
               feedback.timestamp >= (lastFeedbackAction?.feedbackTimestamp ?? .distantPast),
               let record = records.last(where: { $0.id == feedback.episodeID }) {
                lastFeedbackAction = LastFeedbackAction(target: target(record), feedbackTimestamp: feedback.timestamp,
                                                        kind: .episode(feedback.label))
            }
        } catch {
            storageErrorMessage = "Ошибка чтения журнала"
        }
    }

    private func observeWorkspaceBoundaries() {
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.sessionDidBecomeActiveNotification,
            NSWorkspace.screensDidWakeNotification
        ]
        for name in names {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                guard let self else { return }
                self.workspaceSession.receive(event.name)
                self.refreshSessionActivity()
            })
        }
    }

    private func refreshSessionActivity() {
        let active = workspaceSession.canMonitor(consoleIsUsable: WorkspaceSessionState.consoleIsUsable)
        guard active != sessionActive else { return }
        if sessionActive { closeEpisodeForBoundary() }
        sessionActive = active
        if active {
            cameraRetryAfter = nil
        } else {
            camera.stop()
        }
        resetForBoundary(message: active ? "Жду подтверждения присутствия" : "Сессия неактивна")
        updateMenu()
    }

    private func resetForBoundary(message: String) {
        warningPanel.hide()
        _ = stateMachine.resetSession()
        camera.poseShadowEnabled = false
        camera.resetDecisionEvidence()
        previousIdle = nil
        previousTickUptime = nil
        needsInputAnchor = true
        replayQuietEpisodeStarted = false
        quietEpisodeHasObservedStart = false
        currentReading = .unknown()
        statusMessage = message
    }

    private func closeEpisodeForBoundary(now: Date = Date()) {
        guard monitoringEnabled, sessionActive else { return }
        let idle = previousIdle ?? 0
        let closesEpisode = quietEpisodeHasObservedStart && !episodeClosedForCurrentIdle
            && idle >= configuration.probeIdleSeconds
        let id = UUID()
        guard appendRecord(
            id: id,
            now: now,
            event: closesEpisode ? "episodeBoundary" : "sessionBoundary",
            idleSeconds: idle
        ) else { return }
        if closesEpisode {
            episodeClosedForCurrentIdle = true
            latestEpisode = (FeedbackTarget(id: id, timestamp: now, idleSeconds: idle), nil)
        }
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        alert.alertStyle = .warning
        alert.runModal()
    }

    static func dataDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PresenceLock", isDirectory: true)
    }

    private static func label(for state: PresenceState) -> String {
        switch state {
        case .launchGuard: return "Жду подтверждения присутствия"
        case .active: return "Вы работаете"
        case .quiet: return "Нет ввода"
        case .presentQuiet: return "Вы у экрана"
        case .suspectedAway: return "Проверяю уход"
        case .warning: return "Прогноз блокировки"
        case .unknown: return "Присутствие неизвестно"
        case .triggered: return "Прогноз записан"
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()

    private static func shortDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds)) с" }
        return "\(Int(seconds) / 60) мин \(Int(seconds) % 60) с"
    }

    private static func targetDate(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }
}
