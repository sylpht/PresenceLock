import AppKit

final class WarningPanelController: NSObject {
    private let panel: NSPanel
    private let titleLabel = NSTextField(labelWithString: "")
    private let countdownLabel = NSTextField(labelWithString: "")
    private let explanationLabel = NSTextField(wrappingLabelWithString: "")
    private let countdownFont = NSFont.monospacedDigitSystemFont(ofSize: 42, weight: .bold)
    private let checkingFont = NSFont.systemFont(ofSize: 20, weight: .semibold)
    private var timer: Timer?
    private var deadlineMonotonic: TimeInterval = 0
    private var performsRealLock = false

    var onPresent: (() -> Void)?
    var onPause: (() -> Void)?

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
    }

    deinit {
        timer?.invalidate()
    }

    func show(deadlineMonotonic: TimeInterval, performsRealLock: Bool) {
        timer?.invalidate()
        timer = nil
        self.performsRealLock = performsRealLock
        self.deadlineMonotonic = deadlineMonotonic
        titleLabel.stringValue = performsRealLock
            ? L10n.text("Похоже, вы отошли")
            : L10n.text("Проверка PresenceLock")
        explanationLabel.stringValue = performsRealLock
            ? L10n.text("Нажмите «Я здесь» или просто используйте клавиатуру, мышь или трекпад.")
            : L10n.text("Это прогноз. Можно продолжать работу — PresenceLock сам завершит проверку.")
        updateCountdown()
        panel.center()
        panel.orderFrontRegardless()
        guard deadlineMonotonic > ProcessInfo.processInfo.systemUptime else { return }
        timer = Timer.scheduledTimer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(updateCountdown),
            userInfo: nil,
            repeats: true
        )
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func hide() {
        timer?.invalidate()
        timer = nil
        panel.orderOut(nil)
    }

    private func configurePanel() {
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true

        guard let contentView = panel.contentView else { return }
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        countdownLabel.font = countdownFont
        countdownLabel.alignment = .center
        explanationLabel.textColor = .secondaryLabelColor
        explanationLabel.alignment = .center

        let presentButton = NSButton(title: L10n.text("Я здесь"), target: self, action: #selector(confirmPresent))
        presentButton.keyEquivalent = "\r"
        presentButton.bezelStyle = .rounded
        let pauseButton = NSButton(
            title: L10n.text("Пауза на 30 минут"),
            target: self,
            action: #selector(pauseThirtyMinutes)
        )
        pauseButton.bezelStyle = .rounded
        let buttons = NSStackView(views: [presentButton, pauseButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        buttons.alignment = .centerY

        let stack = NSStackView(views: [titleLabel, countdownLabel, explanationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            explanationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func updateCountdown() {
        let remaining = max(0, deadlineMonotonic - ProcessInfo.processInfo.systemUptime)
        if remaining > 0 {
            let seconds = Int(ceil(remaining))
            countdownLabel.font = countdownFont
            countdownLabel.stringValue = performsRealLock ? "\(seconds)" : L10n.format("%1$@ с", String(seconds))
        } else {
            countdownLabel.font = checkingFont
            countdownLabel.stringValue = L10n.text("Проверяю свежий кадр…")
            timer?.invalidate()
            timer = nil
        }
    }

    @objc private func confirmPresent() {
        hide()
        onPresent?()
    }

    @objc private func pauseThirtyMinutes() {
        hide()
        onPause?()
    }
}
