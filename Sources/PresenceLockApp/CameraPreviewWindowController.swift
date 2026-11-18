import AppKit
import AVFoundation
import PresenceLockCore

final class CameraPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let statusLabel = NSTextField(wrappingLabelWithString: "Ожидание камеры")
    private let preview = CameraPreviewView(frame: .zero)
    private var statusText = "Ожидание камеры"

    var onClose: (() -> Void)?
    var isVisible: Bool { window?.isVisible == true }
    var lastFrameUptime: TimeInterval? { preview.lastObservation?.capturedAtMonotonic }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { preview.videoPreviewLayer }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 610, height: 510),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Как видит PresenceLock"
        window.contentMinSize = NSSize(width: 310, height: 260)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        buildInterface()
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        if !isVisible { window?.center() }
        showWindow(nil)
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func setWaiting(_ title: String, showVideo: Bool = false) {
        statusText = title
        preview.lastObservation = nil
        preview.setVideoVisible(showVideo)
        refreshVideoStatus()
    }

    func refreshVideoStatus() {
        let message = isVisible && preview.hasActiveVideo
            ? "\(statusText) · Видеопоток активен"
            : statusText
        if statusLabel.stringValue != message { statusLabel.stringValue = message }
    }

    func display(_ frame: CameraDiagnosticObservation) {
        guard isVisible else { return }
        switch frame.observation {
        case .present:
            statusText = "Человек виден"
        case .absent:
            statusText = "Человек не обнаружен"
        case .unknown:
            switch frame.quality {
            case .usable:
                statusText = "По этому кадру определить не удалось"
            case .rejected:
                statusText = "Кадр слишком тёмный, яркий или однотонный"
            case .analysisFailed:
                statusText = "Не удалось обработать кадр"
            }
        }
        preview.lastObservation = frame
        preview.setVideoVisible(true)
        refreshVideoStatus()
    }

    func windowWillClose(_ notification: Notification) {
        setWaiting("Ожидание камеры")
        onClose?()
    }

    private func buildInterface() {
        guard let content = window?.contentView else { return }
        statusLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        let legend = NSStackView(views: [
            Self.legendLabel("Лицо", color: CameraPreviewView.faceColor),
            Self.legendLabel("Верх тела", color: CameraPreviewView.bodyColor)
        ])
        legend.orientation = .horizontal
        legend.spacing = 16
        legend.setContentCompressionResistancePriority(.required, for: .vertical)

        for view in [statusLabel, preview, legend] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            preview.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            preview.leadingAnchor.constraint(equalTo: statusLabel.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: statusLabel.trailingAnchor),
            legend.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 12),
            legend.leadingAnchor.constraint(equalTo: preview.leadingAnchor),
            legend.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16)
        ])
    }

    private static func legendLabel(_ title: String, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        let text = NSMutableAttributedString(string: "■ ", attributes: [.foregroundColor: color])
        text.append(NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.labelColor]))
        label.attributedStringValue = text
        label.setAccessibilityLabel(title)
        return label
    }
}

private final class CameraPreviewView: NSView {
    static let faceColor = NSColor.systemGreen
    static let bodyColor = NSColor.systemCyan

    let videoPreviewLayer = AVCaptureVideoPreviewLayer()
    private let overlayLayer = CALayer()
    private let faceOutline = CAShapeLayer()
    private let faceStroke = CAShapeLayer()
    private let bodyOutline = CAShapeLayer()
    private let bodyStroke = CAShapeLayer()

    var lastObservation: CameraDiagnosticObservation? {
        didSet {
            if oldValue != nil || lastObservation != nil { updateOutlines() }
        }
    }

    var hasActiveVideo: Bool {
        !videoPreviewLayer.isHidden
            && videoPreviewLayer.session?.isRunning == true
            && videoPreviewLayer.connection?.isActive == true
            && videoPreviewLayer.connection?.isEnabled == true
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let backing = CALayer()
        backing.backgroundColor = NSColor.black.cgColor
        backing.masksToBounds = true
        layer = backing
        wantsLayer = true

        videoPreviewLayer.videoGravity = .resizeAspect
        videoPreviewLayer.isHidden = true
        backing.addSublayer(videoPreviewLayer)
        backing.addSublayer(overlayLayer)
        overlayLayer.masksToBounds = true

        for (shape, color, width) in [
            (bodyOutline, NSColor.black.withAlphaComponent(0.8), CGFloat(5)),
            (bodyStroke, Self.bodyColor, CGFloat(2.5)),
            (faceOutline, NSColor.black.withAlphaComponent(0.8), CGFloat(5)),
            (faceStroke, Self.faceColor, CGFloat(2.5))
        ] {
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = width
            overlayLayer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer.frame = bounds
        CATransaction.commit()
        updateOutlines()
    }

    func setVideoVisible(_ visible: Bool) {
        guard videoPreviewLayer.isHidden == visible else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        videoPreviewLayer.isHidden = !visible
        CATransaction.commit()
        updateOutlines()
    }

    private func updateOutlines() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if let lastObservation, !videoPreviewLayer.isHidden, videoPreviewLayer.connection != nil {
            let aperture = videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: Self.unitRect)
                .intersection(videoPreviewLayer.bounds)
            if !aperture.isEmpty, !aperture.isInfinite {
                overlayLayer.frame = aperture
                let area = overlayLayer.bounds
                faceOutline.frame = area
                faceStroke.frame = area
                bodyOutline.frame = area
                bodyStroke.frame = area
                let faces = Self.path(for: lastObservation.faceBoxes, within: area)
                let bodies = Self.path(for: lastObservation.bodyBoxes, within: area)
                faceOutline.path = faces
                faceStroke.path = faces
                bodyOutline.path = bodies
                bodyStroke.path = bodies
                return
            }
        }
        faceOutline.path = nil
        faceStroke.path = nil
        bodyOutline.path = nil
        bodyStroke.path = nil
    }

    private static let unitRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    private static func path(for boxes: [CGRect], within aperture: CGRect) -> CGPath? {
        guard !boxes.isEmpty else { return nil }
        let path = CGMutablePath()
        for box in boxes {
            let normalized = box.intersection(unitRect)
            guard !normalized.isEmpty else { continue }
            // Both Vision and the AppKit backing layer use a lower-left origin.
            // The preview connection already matches the analyzed video's orientation.
            path.addRect(CGRect(
                x: aperture.minX + normalized.minX * aperture.width,
                y: aperture.minY + normalized.minY * aperture.height,
                width: normalized.width * aperture.width,
                height: normalized.height * aperture.height
            ))
        }
        return path.isEmpty ? nil : path
    }
}
