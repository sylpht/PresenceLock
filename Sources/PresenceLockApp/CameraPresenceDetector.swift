import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import PresenceLockCore
import Vision

/// The diagnostic result of the most recently analyzed camera frame.
struct CameraDiagnosticObservation {
    enum Quality {
        case usable
        case rejected
        case analysisFailed
    }

    let faceBoxes: [CGRect]
    let bodyBoxes: [CGRect]
    let observation: PresenceObservation
    let capturedAtMonotonic: TimeInterval
    let quality: Quality
}

final class CameraPresenceDetector: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    struct DecisionSnapshot {
        let monotonicTime: TimeInterval
        let reading: PresenceReading
        let evidence: CameraTickEvidence
        let poseShadow: PoseShadowSample?
    }

    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "local.aszzi.presencelock.camera")
    private let poseQueue = DispatchQueue(label: "local.aszzi.presencelock.shadow-pose", qos: .utility)
    private let stateLock = NSLock()

    private var configured = false
    // The preview connection and video output are managed on captureQueue.
    private var diagnosticPreviewLayer: AVCaptureVideoPreviewLayer?
    private var analysisVideoOutput: AVCaptureVideoDataOutput?
    private var deviceDisconnectObserver: NSObjectProtocol?
    private var running = false
    private var desiredRunning = false
    private var recovering = false
    private static let sampleDeliveryTimeout: TimeInterval = 15
    private var lastDeliveryOrStartAt: TimeInterval?
    private var lastProcessedAt: TimeInterval?
    private var _processingInterval: TimeInterval = 2
    private var _latestReading = PresenceReading.unknown()
    private var decisionEvidence = CameraTickEvidence.none
    private var decisionGeneration: UInt64 = 0
    private var earliestCaptureTime: TimeInterval = 0
    private var _poseShadowEnabled = false
    private var poseEnabledSince: TimeInterval = 0
    private var poseGeneration: UInt64 = 0
    private var poseBusy = false
    private var lastPoseRequestAt: TimeInterval?
    private var pendingPose: PoseShadowSample?
    private var notificationTokens: [NSObjectProtocol] = []
    private var diagnosticObservationHandler: ((CameraDiagnosticObservation) -> Void)?
    private var diagnosticGeneration: UInt64 = 0
    private var pendingDiagnosticGeneration: UInt64?

    var onHardFailure: (() -> Void)?

    var poseShadowEnabled: Bool {
        get { stateLock.withLock { _poseShadowEnabled } }
        set {
            stateLock.withLock {
                guard newValue != _poseShadowEnabled else { return }
                _poseShadowEnabled = newValue
                if newValue { poseEnabledSince = ProcessInfo.processInfo.systemUptime }
                invalidatePoseLocked()
            }
        }
    }

    var processingInterval: TimeInterval {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _processingInterval
        }
        set {
            stateLock.lock()
            _processingInterval = max(0.25, newValue)
            stateLock.unlock()
        }
    }

    var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    override init() {
        super.init()
        observeSessionNotifications()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        if let deviceDisconnectObserver { NotificationCenter.default.removeObserver(deviceDisconnectObserver) }
    }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async { completion(granted) }
            }
        default:
            completion(false)
        }
    }

    func start() {
        let now = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        if desiredRunning {
            stateLock.unlock()
            // The controller renews demand every tick. Failure is checked under the
            // same lock as raw delivery, so a frame arriving in between wins.
            handleHardFailure(ifSilentAt: now)
            return
        }
        guard !recovering else {
            stateLock.unlock()
            return
        }
        desiredRunning = true
        lastDeliveryOrStartAt = now
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self, self.captureRequested else { return }
            do {
                try self.configureIfNeeded()
                guard self.captureRequested else { return }
                guard !self.session.isRunning else {
                    self.setRunning(true)
                    return
                }
                self.session.startRunning()
                self.setRunning(self.session.isRunning)
                if !self.session.isRunning {
                    self.handleHardFailure()
                }
            } catch {
                self.handleHardFailure()
            }
        }
    }

    private var captureRequested: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return desiredRunning && !recovering
    }

    func stop() {
        stateLock.lock()
        guard desiredRunning || running else {
            stateLock.unlock()
            return
        }
        desiredRunning = false
        running = false
        lastDeliveryOrStartAt = nil
        invalidateDecisionReadingLocked(cameraAvailable: true)
        invalidateDiagnosticObservationsLocked()
        stateLock.unlock()

        captureQueue.async { [weak self] in
            guard let self else { return }
            self.session.stopRunning()
            self.setRunning(false)
        }
    }

    func decisionSnapshot(consumeEvidence: Bool = true) -> DecisionSnapshot {
        stateLock.lock()
        defer { stateLock.unlock() }
        // The timestamp and reading share this lock, so a frame published just after
        // the decision boundary stays available for the next decision.
        let now = ProcessInfo.processInfo.systemUptime
        if let pose = pendingPose, !Self.freshPoseTime(pose.capturedAtMonotonic, at: now) {
            pendingPose = nil
        }
        let snapshot = DecisionSnapshot(
            monotonicTime: now,
            reading: _latestReading,
            evidence: decisionEvidence,
            poseShadow: pendingPose
        )
        if consumeEvidence {
            decisionEvidence = .none
            pendingPose = nil
        }
        return snapshot
    }

    func resetDecisionEvidence() {
        stateLock.lock()
        defer { stateLock.unlock() }
        invalidateDecisionReadingLocked(cameraAvailable: _latestReading.cameraAvailable)
    }

    /// Attaches a display-only connection to the existing session without starting the camera.
    func setDiagnosticPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        captureQueue.async { [weak self] in
            guard let self, self.diagnosticPreviewLayer !== layer else { return }
            self.diagnosticPreviewLayer?.session = nil
            self.diagnosticPreviewLayer = layer
            self.connectDiagnosticPreviewIfConfigured()
        }
    }

    /// Subscribes to recognition results on the main queue without delivering pixel data.
    func setDiagnosticObservationHandler(_ handler: ((CameraDiagnosticObservation) -> Void)?) {
        stateLock.lock()
        diagnosticObservationHandler = handler
        invalidateDiagnosticObservationsLocked()
        stateLock.unlock()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // A callback queued by a disconnected camera can arrive after it was replaced.
        guard output === analysisVideoOutput else { return }
        let callbackUptime = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        let acceptsFrames = desiredRunning && running && !recovering
        if acceptsFrames { lastDeliveryOrStartAt = callbackUptime }
        let interval = _processingInterval
        let frameGeneration = decisionGeneration
        let shadowGeneration = _poseShadowEnabled ? poseGeneration : nil
        let previewGeneration = diagnosticObservationHandler == nil ? nil : diagnosticGeneration
        let shouldProcess = lastProcessedAt.map { callbackUptime - $0 >= interval } ?? true
        if acceptsFrames && shouldProcess { lastProcessedAt = callbackUptime }
        stateLock.unlock()
        guard acceptsFrames, shouldProcess else { return }

        let callbackDate = Date()
        let hostClock = CMClockGetHostTimeClock()
        let captureAge = session.synchronizationClock.map { clock in
            let timestamp = clock.convertTime(sampleBuffer.presentationTimeStamp, to: hostClock)
            return CMTimeSubtract(CMClockGetTime(hostClock), timestamp).seconds
        }
        guard let captureAge, captureAge.isFinite, captureAge >= 0, captureAge <= callbackUptime else {
            let reading = PresenceReading.unknown(at: callbackDate, monotonic: callbackUptime, cameraAvailable: true)
            publishFrame(reading, generation: frameGeneration)
            if let previewGeneration {
                deliverDiagnosticObservation(generation: previewGeneration, reading: reading, quality: .analysisFailed)
            }
            return
        }
        let now = callbackDate.addingTimeInterval(-captureAge)
        let monotonicNow = callbackUptime - captureAge

        guard frameIsUsable(sampleBuffer) else {
            let reading = PresenceReading.unknown(at: now, monotonic: monotonicNow, cameraAvailable: true)
            publishFrame(reading, generation: frameGeneration)
            if let previewGeneration {
                deliverDiagnosticObservation(generation: previewGeneration, reading: reading, quality: .rejected)
            }
            return
        }

        let faceRequest = VNDetectFaceRectanglesRequest()
        let humanRequest = VNDetectHumanRectanglesRequest()
        humanRequest.upperBodyOnly = true

        do {
            let handler = VNImageRequestHandler(cmSampleBuffer: sampleBuffer, orientation: .up)
            try handler.perform([faceRequest, humanRequest])

            let faceConfidence = faceRequest.results?.map { Double($0.confidence) }.max() ?? 0
            let humanConfidence = humanRequest.results?.map { Double($0.confidence) }.max() ?? 0
            let confidence = max(faceConfidence, humanConfidence)
            let observation = Self.observation(faceCount: faceRequest.results?.count,
                                               bodyCount: humanRequest.results?.count)

            let reading = PresenceReading(
                observation: observation,
                confidence: observation == .present ? confidence : (observation == .absent ? 1 : 0),
                capturedAt: now,
                capturedAtMonotonic: monotonicNow,
                cameraAvailable: true
            )
            publishFrame(reading, generation: frameGeneration)
            if observation == .absent, let shadowGeneration, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                scheduleShadowPose(pixels, capturedAt: monotonicNow, generation: shadowGeneration)
            }
            if let previewGeneration {
                deliverDiagnosticObservation(
                    generation: previewGeneration,
                    reading: reading,
                    quality: observation == .unknown ? .analysisFailed : .usable,
                    faceBoxes: faceRequest.results?.map(\.boundingBox) ?? [],
                    bodyBoxes: humanRequest.results?.map(\.boundingBox) ?? []
                )
            }
        } catch {
            let reading = PresenceReading.unknown(at: now, monotonic: monotonicNow, cameraAvailable: true)
            publishFrame(reading, generation: frameGeneration)
            if let previewGeneration {
                deliverDiagnosticObservation(generation: previewGeneration, reading: reading, quality: .analysisFailed)
            }
        }
    }

    static func observation(faceCount: Int?, bodyCount: Int?) -> PresenceObservation {
        if (faceCount ?? 0) > 0 || (bodyCount ?? 0) > 0 { return .present }
        return faceCount == 0 && bodyCount == 0 ? .absent : .unknown
    }

    private func configureIfNeeded() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw CameraError.notAuthorized
        }
        if configured {
            if let input = session.inputs.first as? AVCaptureDeviceInput, input.device.isConnected { return }
            discardCaptureConfiguration()
        }
        guard let device = preferredCamera() else {
            throw CameraError.noCamera
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        output.setSampleBufferDelegate(self, queue: captureQueue)

        session.beginConfiguration()
        defer {
            session.commitConfiguration()
            connectDiagnosticPreviewIfConfigured()
        }
        session.sessionPreset = .vga640x480
        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw CameraError.cannotConfigure
        }
        session.addInput(input)
        session.addOutput(output)
        analysisVideoOutput = output
        deviceDisconnectObserver = NotificationCenter.default.addObserver(
            forName: AVCaptureDevice.wasDisconnectedNotification, object: device, queue: nil
        ) { [weak self] _ in self?.handleHardFailure() }
        configured = true
    }

    // Always called on the capture queue, outside any existing configuration transaction.
    private func discardCaptureConfiguration() {
        // stopRunning also withdraws the request that AVFoundation could otherwise
        // automatically resume after an interruption, even while monitoring is paused.
        session.stopRunning()
        if let deviceDisconnectObserver { NotificationCenter.default.removeObserver(deviceDisconnectObserver) }
        deviceDisconnectObserver = nil
        diagnosticPreviewLayer?.session = nil
        analysisVideoOutput?.setSampleBufferDelegate(nil, queue: nil)
        session.beginConfiguration()
        for output in session.outputs { session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
        analysisVideoOutput = nil
        configured = false
    }

    private func connectDiagnosticPreviewIfConfigured() {
        guard configured, let diagnosticPreviewLayer else { return }
        diagnosticPreviewLayer.session = session
        matchDiagnosticPreviewTransform()
    }

    private func matchDiagnosticPreviewTransform() {
        guard let previewConnection = diagnosticPreviewLayer?.connection,
              let analysisConnection = analysisVideoOutput?.connection(with: .video) else { return }
        if previewConnection.isVideoMirroringSupported {
            previewConnection.automaticallyAdjustsVideoMirroring = false
            previewConnection.isVideoMirrored = analysisConnection.isVideoMirrored
        }
        let angle = analysisConnection.videoRotationAngle
        if previewConnection.videoRotationAngle != angle,
           previewConnection.isVideoRotationAngleSupported(angle) {
            previewConnection.videoRotationAngle = angle
        }
    }

    private func preferredCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.first(where: { $0.deviceType == .builtInWideAngleCamera })
            ?? discovery.devices.first
            ?? AVCaptureDevice.default(for: .video)
    }

    private func observeSessionNotifications() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.handleHardFailure()
        })
        notificationTokens.append(center.addObserver(
            forName: .AVCaptureSessionRuntimeError,
            object: session,
            queue: nil
        ) { [weak self] _ in
            self?.handleHardFailure()
        })
    }

    private func frameIsUsable(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return false
        }

        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let stepX = max(1, width / 32)
        let stepY = max(1, height / 24)
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)

        var count = 0.0
        var sum = 0.0
        var sumOfSquares = 0.0
        for y in stride(from: 0, to: height, by: stepY) {
            for x in stride(from: 0, to: width, by: stepX) {
                let pixel = bytes.advanced(by: y * bytesPerRow + x * 4)
                let blue = Double(pixel[0])
                let green = Double(pixel[1])
                let red = Double(pixel[2])
                let luminance = 0.0722 * blue + 0.7152 * green + 0.2126 * red
                count += 1
                sum += luminance
                sumOfSquares += luminance * luminance
            }
        }

        guard count > 0 else { return false }
        let mean = sum / count
        let variance = max(0, sumOfSquares / count - mean * mean)
        return mean >= 12 && mean <= 245 && variance >= 9
    }

    private func publishFrame(_ reading: PresenceReading, generation: UInt64) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard desiredRunning, running, !recovering, decisionGeneration == generation,
              reading.capturedAtMonotonic >= earliestCaptureTime else { return }
        _latestReading = reading
        switch reading.observation {
        case .present: decisionEvidence.sawPresence = true
        case .unknown: decisionEvidence.sawUncertainty = true
        case .absent: break
        }
    }

    private static func freshPoseTime(_ capturedAt: TimeInterval, at now: TimeInterval) -> Bool {
        let age = now - capturedAt
        return age >= 0 && age <= DetectionConfiguration.learningDefault.maximumSampleAgeSeconds
    }

    private func scheduleShadowPose(_ pixels: CVPixelBuffer, capturedAt: TimeInterval, generation: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        let accepted = stateLock.withLock {
            guard _poseShadowEnabled, poseGeneration == generation, desiredRunning, running, !recovering,
                  !poseBusy, capturedAt >= max(earliestCaptureTime, poseEnabledSince),
                  Self.freshPoseTime(capturedAt, at: now),
                  lastPoseRequestAt.map({ now - $0 >= 2 }) ?? true else { return false }
            poseBusy = true
            lastPoseRequestAt = now
            return true
        }
        guard accepted else { return }
        // Retain just this read-only pixel buffer until inference returns; additional frames are dropped.
        poseQueue.async { [weak self] in
            guard let self else { return }
            let current = self.stateLock.withLock { self.poseGeneration == generation }
            let result = current && Self.freshPoseTime(capturedAt, at: ProcessInfo.processInfo.systemUptime)
                ? autoreleasepool { UpperBodyPoseEvidence.evaluate(pixels) } : .unavailable
            self.stateLock.withLock {
                self.poseBusy = false
                guard self.poseGeneration == generation,
                      Self.freshPoseTime(capturedAt, at: ProcessInfo.processInfo.systemUptime) else { return }
                self.pendingPose = PoseShadowSample(capturedAtMonotonic: capturedAt, result: result)
            }
        }
    }

    /// The worker retains its busy slot across boundaries until it releases the old frame.
    private func invalidatePoseLocked() {
        poseGeneration &+= 1
        pendingPose = nil
    }

    private func deliverDiagnosticObservation(
        generation: UInt64,
        reading: PresenceReading,
        quality: CameraDiagnosticObservation.Quality,
        faceBoxes: [CGRect] = [],
        bodyBoxes: [CGRect] = []
    ) {
        stateLock.lock()
        guard diagnosticGeneration == generation,
              pendingDiagnosticGeneration == nil,
              desiredRunning, running, !recovering else {
            stateLock.unlock()
            return
        }
        pendingDiagnosticGeneration = generation
        stateLock.unlock()

        let observation = CameraDiagnosticObservation(
            faceBoxes: faceBoxes,
            bodyBoxes: bodyBoxes,
            observation: reading.observation,
            capturedAtMonotonic: reading.capturedAtMonotonic,
            quality: quality
        )
        DispatchQueue.main.async { [weak self] in
            self?.takeDiagnosticObservationHandler(generation: generation)?(observation)
        }
    }

    private func takeDiagnosticObservationHandler(generation: UInt64) -> ((CameraDiagnosticObservation) -> Void)? {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard diagnosticGeneration == generation, pendingDiagnosticGeneration == generation else { return nil }
        pendingDiagnosticGeneration = nil
        return desiredRunning && running && !recovering ? diagnosticObservationHandler : nil
    }

    /// Requires stateLock and invalidates any result already waiting for the main queue.
    private func invalidateDiagnosticObservationsLocked() {
        diagnosticGeneration &+= 1
        pendingDiagnosticGeneration = nil
    }

    /// Requires stateLock. Ignore outstanding frames from before the capture boundary.
    private func invalidateDecisionReadingLocked(cameraAvailable: Bool) {
        decisionGeneration &+= 1
        invalidatePoseLocked()
        earliestCaptureTime = ProcessInfo.processInfo.systemUptime
        lastProcessedAt = nil
        _latestReading = .unknown(cameraAvailable: cameraAvailable)
        decisionEvidence = CameraTickEvidence(sawUncertainty: true)
    }

    private func setRunning(_ value: Bool) {
        stateLock.lock()
        let active = value && desiredRunning && !recovering
        if active && !running { lastDeliveryOrStartAt = ProcessInfo.processInfo.systemUptime }
        running = active
        stateLock.unlock()
    }

    private func handleHardFailure(ifSilentAt checkedAt: TimeInterval? = nil) {
        stateLock.lock()
        guard desiredRunning || running else { stateLock.unlock(); return }
        if let checkedAt {
            guard let lastDeliveryOrStartAt,
                  checkedAt - lastDeliveryOrStartAt >= Self.sampleDeliveryTimeout else {
                stateLock.unlock()
                return
            }
        }
        recovering = true
        desiredRunning = false
        running = false
        lastDeliveryOrStartAt = nil
        invalidateDecisionReadingLocked(cameraAvailable: false)
        invalidateDiagnosticObservationsLocked()
        stateLock.unlock()
        captureQueue.async { [weak self] in
            guard let self else { return }
            self.discardCaptureConfiguration()
            self.stateLock.lock()
            self.recovering = false
            self.stateLock.unlock()
        }
        DispatchQueue.main.async { [weak self] in
            self?.onHardFailure?()
        }
    }

    private enum CameraError: Error {
        case notAuthorized
        case noCamera
        case cannotConfigure
    }
}
