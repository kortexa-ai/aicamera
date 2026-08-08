import AICameraCore
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class VideoPipelineController: NSObject {
    typealias PreviewHandler = @Sendable (NSImage) -> Void
    typealias GestureHandler = @Sendable ([GestureObservation], FrameID) -> Void
    typealias FrameHandler = @Sendable (FrameAnalysisPacket) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: AICameraConfiguration
    private let onPreview: PreviewHandler
    private let onGestures: GestureHandler
    private let onFrame: FrameHandler
    private let onError: ErrorHandler

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "ai.kortexa.aicamera.video-capture", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "ai.kortexa.aicamera.video-analysis", qos: .userInitiated)
    private let renderer = OverlayRenderer()
    /// Confined to analysisQueue so network inputs never contain rendered private overlays.
    private let analysisRenderer = OverlayRenderer()
    private let gestureDetector = GestureDetector()
    private let feeder = VirtualCameraFeeder()

    private let snapshotLock = NSLock()
    private var snapshot = SceneSnapshot()
    private var frameCounter: UInt64 = 0
    private var lastPreviewUptime: TimeInterval = 0
    private var lastGestureUptime: TimeInterval = 0
    private var lastNetworkUptime: TimeInterval = 0
    private var gestureInFlight = false
    private var networkInFlight = false
    // Protected by snapshotLock and copied into analysis work to reject late callbacks after stop.
    private var runGeneration: UInt64 = 0
    private var runIsActive = false

    var isFeedingVirtualCamera: Bool { feeder.isRunning }

    init(
        configuration: AICameraConfiguration,
        onPreview: @escaping PreviewHandler,
        onGestures: @escaping GestureHandler,
        onFrame: @escaping FrameHandler,
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.onPreview = onPreview
        self.onGestures = onGestures
        self.onFrame = onFrame
        self.onError = onError
        super.init()
    }

    func start() throws {
        snapshotLock.lock()
        guard !runIsActive else { snapshotLock.unlock(); return }
        runGeneration &+= 1
        runIsActive = true
        snapshotLock.unlock()
        do {
            try configureSession()
        } catch {
            endRun()
            throw error
        }
        let capture = configuration.capture
        do {
            try feeder.start(configuration: .init(
                width: Int32(capture.width),
                height: Int32(capture.height),
                framesPerSecond: Int32(capture.framesPerSecond)
            ))
        } catch {
            onError("Virtual camera is not receiving frames yet: \(error.localizedDescription)")
        }
        captureQueue.async { [weak self] in
            guard let self, self.currentGeneration() != nil else { return }
            self.session.startRunning()
        }
    }

    func stop() {
        guard endRun() else { return }
        videoOutput.setSampleBufferDelegate(nil, queue: nil)
        captureQueue.sync {
            if session.isRunning { session.stopRunning() }
            gestureInFlight = false
            networkInFlight = false
        }
        feeder.stop()
    }

    func update(snapshot: SceneSnapshot) {
        snapshotLock.lock()
        self.snapshot = snapshot
        snapshotLock.unlock()
    }

    private func currentGeneration() -> UInt64? {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return runIsActive ? runGeneration : nil
    }

    private func isActive(generation: UInt64) -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return runIsActive && runGeneration == generation
    }

    @discardableResult
    private func endRun() -> Bool {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        guard runIsActive else { return false }
        runIsActive = false
        runGeneration &+= 1
        return true
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .high

        guard let device = selectedCamera() else {
            let message = configuration.capture.videoDeviceID == nil
                ? "No hardware camera is available."
                : "The configured camera is not available. Select another camera or Automatic."
            throw NSError(domain: "AICamera.Video", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        try configure(device: device)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "AICamera.Video", code: 2, userInfo: [NSLocalizedDescriptionKey: "The selected camera cannot be added to the capture session."])
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard session.canAddOutput(videoOutput) else {
            throw NSError(domain: "AICamera.Video", code: 3, userInfo: [NSLocalizedDescriptionKey: "Video output is unavailable."])
        }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: captureQueue)
    }

    private func selectedCamera() -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        let hardware = discovery.devices.filter { $0.uniqueID != AICameraVirtualCamera.deviceUID }
        if let requested = configuration.capture.videoDeviceID {
            return hardware.first(where: { $0.uniqueID == requested })
        }
        return hardware.first
    }

    private func configure(device: AVCaptureDevice) throws {
        let requestedWidth = Int32(configuration.capture.width)
        let requestedHeight = Int32(configuration.capture.height)
        let requestedFPS = Double(configuration.capture.framesPerSecond)
        let candidates = device.formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return format.videoSupportedFrameRateRanges.contains { range in
                requestedFPS >= range.minFrameRate && requestedFPS <= range.maxFrameRate
            } && dimensions.width > 0 && dimensions.height > 0
        }
        guard let best = candidates.min(by: { lhs, rhs in
            let left = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let right = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            let leftScore = abs(left.width - requestedWidth) + abs(left.height - requestedHeight)
            let rightScore = abs(right.width - requestedWidth) + abs(right.height - requestedHeight)
            return leftScore < rightScore
        }) else {
            throw NSError(
                domain: "AICamera.Video",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The selected camera does not support \(configuration.capture.framesPerSecond) fps."]
            )
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best
        let duration = CMTime(value: 1, timescale: CMTimeScale(configuration.capture.framesPerSecond))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func currentSnapshot() -> SceneSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return snapshot
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let generation = currentGeneration(),
              let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        frameCounter &+= 1
        let frameID = FrameID(rawValue: frameCounter)
        guard let output = renderer.render(
            input: input,
            capture: configuration.capture,
            overlay: configuration.overlays,
            snapshot: currentSnapshot()
        ) else { return }

        if feeder.isRunning, let outgoing = makeSampleBuffer(pixelBuffer: output, source: sampleBuffer) {
            do { _ = try feeder.enqueue(outgoing) }
            catch { onError("Virtual camera feed: \(error.localizedDescription)") }
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastPreviewUptime >= 1 / 12, let image = renderer.previewImage(from: output) {
            lastPreviewUptime = uptime
            onPreview(image)
        }
        submitGestureIfNeeded(pixelBuffer: input, frameID: frameID, uptime: uptime, generation: generation)
        submitNetworkFrameIfNeeded(pixelBuffer: input, frameID: frameID, uptime: uptime, generation: generation)
    }

    private func submitGestureIfNeeded(
        pixelBuffer: CVPixelBuffer,
        frameID: FrameID,
        uptime: TimeInterval,
        generation: UInt64
    ) {
        guard let stage = configuration.pipeline.videoStages.first(where: { $0.enabled && $0.kind == .handGesture }),
              !gestureInFlight,
              uptime - lastGestureUptime >= 1 / stage.maximumRateHz else { return }
        gestureInFlight = true
        lastGestureUptime = uptime
        let mirrored = configuration.capture.mirrorVideo
        analysisQueue.async { [weak self] in
            guard let self, self.isActive(generation: generation) else { return }
            let observations = self.gestureDetector.detect(in: pixelBuffer, mirrored: mirrored)
            guard self.isActive(generation: generation) else { return }
            self.onGestures(observations, frameID)
            self.captureQueue.async { [weak self] in self?.gestureInFlight = false }
        }
    }

    private func submitNetworkFrameIfNeeded(
        pixelBuffer: CVPixelBuffer,
        frameID: FrameID,
        uptime: TimeInterval,
        generation: UInt64
    ) {
        let rates = configuration.pipeline.videoStages
            .filter { $0.enabled && $0.kind != .handGesture }
            .map(\.maximumRateHz)
        guard let maximumRate = rates.max(),
              !networkInFlight,
              uptime - lastNetworkUptime >= 1 / maximumRate else { return }
        networkInFlight = true
        lastNetworkUptime = uptime
        let capturedAt = Date()
        let capture = configuration.capture
        analysisQueue.async { [weak self] in
            guard let self, self.isActive(generation: generation) else { return }
            // Apply the same aspect-fill and mirror transform as the published frame, but
            // do not burn transcript, agent, gesture, or detection overlays into AI input.
            let noOverlays = OverlayConfiguration(enabled: false)
            if let clean = self.analysisRenderer.render(
                input: pixelBuffer,
                capture: capture,
                overlay: noOverlays,
                snapshot: SceneSnapshot()
            ), let encoded = self.analysisRenderer.jpeg(from: clean),
               self.isActive(generation: generation) {
                self.onFrame(.init(
                    frameID: frameID,
                    capturedAt: capturedAt,
                    jpegData: encoded.data,
                    width: encoded.width,
                    height: encoded.height
                ))
            }
            self.captureQueue.async { [weak self] in self?.networkInFlight = false }
        }
    }

    private func makeSampleBuffer(pixelBuffer: CVPixelBuffer, source: CMSampleBuffer) -> CMSampleBuffer? {
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr, let description else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(configuration.capture.framesPerSecond)),
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(source),
            decodeTimeStamp: .invalid
        )
        var output: CMSampleBuffer?
        guard CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }
}

extension VideoPipelineController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        process(sampleBuffer)
    }
}
