import AppKit
import PresenceLockCore

final class PresenceLockSettingsWindowController: NSWindowController {
    private let preferences: PresenceLockPreferences
    private let onSave: (DetectionConfiguration) -> Void
    private let probeField = NSTextField()
    private let absenceField = NSTextField()
    private let warningField = NSTextField()
    private let validationLabel = NSTextField(labelWithString: "")

    init(
        preferences: PresenceLockPreferences,
        onSave: @escaping (DetectionConfiguration) -> Void
    ) {
        self.preferences = preferences
        self.onSave = onSave
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 470, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Настройки PresenceLock"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    func show(configuration: DetectionConfiguration) {
        probeField.stringValue = Self.number(configuration.probeIdleSeconds)
        absenceField.stringValue = Self.number(configuration.absenceConfirmationSeconds)
        warningField.stringValue = Self.number(configuration.warningSeconds)
        validationLabel.isHidden = true
        showWindow(nil)
        window?.center()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func buildInterface() {
        guard let contentView = window?.contentView else { return }
        let title = NSTextField(labelWithString: "Когда считать, что вы отошли")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let note = NSTextField(wrappingLabelWithString:
            "Настройки применяются сразу и сбрасывают текущий отсчёт. "
            + "Боевой режим всё равно нужно включать отдельно после каждого запуска."
        )
        note.textColor = .secondaryLabelColor

        [probeField, absenceField, warningField].forEach {
            $0.alignment = .right
            $0.formatter = Self.numberFormatter
            $0.widthAnchor.constraint(equalToConstant: 92).isActive = true
        }
        let form = NSGridView(views: [
            [NSTextField(labelWithString: "Включать камеру после"), probeField,
             NSTextField(labelWithString: "секунд без ввода")],
            [NSTextField(labelWithString: "Подтверждать отсутствие"), absenceField,
             NSTextField(labelWithString: "секунд")],
            [NSTextField(labelWithString: "Показывать предупреждение"), warningField,
             NSTextField(labelWithString: "секунд")]
        ])
        form.rowSpacing = 10
        form.columnSpacing = 8
        form.column(at: 0).xPlacement = .trailing

        validationLabel.textColor = .systemRed
        validationLabel.isHidden = true

        let resetButton = NSButton(title: "По умолчанию", target: self, action: #selector(resetDefaults))
        let cancelButton = NSButton(title: "Отмена", target: self, action: #selector(cancel))
        let saveButton = NSButton(title: "Сохранить", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [resetButton, spacer, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [title, note, form, validationLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor, constant: -20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            form.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func resetDefaults() {
        let defaults = DetectionConfiguration.learningDefault
        probeField.stringValue = Self.number(defaults.probeIdleSeconds)
        absenceField.stringValue = Self.number(defaults.absenceConfirmationSeconds)
        warningField.stringValue = Self.number(defaults.warningSeconds)
        validationLabel.isHidden = true
    }

    @objc private func cancel() { close() }

    @objc private func save() {
        guard let probe = Self.parse(probeField),
              let absence = Self.parse(absenceField),
              let warning = Self.parse(warningField),
              (5...300).contains(probe),
              (5...300).contains(absence),
              (3...60).contains(warning) else {
            validationLabel.stringValue =
                "Допустимо: камера 5–300 с, отсутствие 5–300 с, предупреждение 3–60 с."
            validationLabel.isHidden = false
            NSSound.beep()
            return
        }
        validationLabel.isHidden = true
        onSave(preferences.makeConfiguration(
            probeIdleSeconds: probe,
            absenceConfirmationSeconds: absence,
            warningSeconds: warning
        ))
        close()
    }

    private static func parse(_ field: NSTextField) -> Double? {
        if let value = numberFormatter.number(from: field.stringValue)?.doubleValue {
            return value
        }
        return Double(field.stringValue.replacingOccurrences(of: ",", with: "."))
    }

    private static func number(_ value: TimeInterval) -> String {
        String(format: "%.0f", value)
    }

    private static let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimum = 0
        formatter.maximumFractionDigits = 0
        formatter.allowsFloats = false
        return formatter
    }()
}
