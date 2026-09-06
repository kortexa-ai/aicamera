import AICameraCore
import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

final class VideoPipelineController: NSObject {
    typealias PreviewHandler = @Sendable (NSImage, PrivacyMuteState.Snapshot, RuntimeFeatureState.Snapshot) -> Void
    typealias GestureHandler = @Sendable ([GestureObservation], FrameID, TimeInterval) -> Void
    typealias FrameHandler = @Sendable (FrameAnalysisPacket) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: AICameraConfiguration
    private let runtimeFeatures: RuntimeFeatureState
    private var snapshotFeatures = RuntimeFeatureState().snapshot
    private let privacyMute: PrivacyMuteState
    private var snapshotPrivacy = PrivacyMuteState().snapshot
    private let onPreview: PreviewHandler
    private let onGestures: GestureHandler
    private let onFrame: FrameHandler
    private let onError: ErrorHandler
    /// Optional script-overlay producer. Read synchronously on the capture
    /// path; a stale or absent overlay never delays a frame.
    private let scriptRenderer: OverlayScriptRenderer?
    private let agentPresentation: AgentPresentationState?
    private let faceAnchors: FaceAnchorState?

    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let captureQueue = DispatchQueue(label: "ai.kortexa.aicamera.video-capture", qos: .userInteractive)
    private let analysisQueue = DispatchQueue(label: "ai.kortexa.aicamera.video-analysis", qos: .userInitiated)
    // Deliberate controls must not queue behind JPEG preparation for object/scene inference.
    private let gestureQueue = DispatchQueue(label: "ai.kortexa.aicamera.gestures", qos: .userInitiated)
    private let faceQueue = DispatchQueue(label: "ai.kortexa.aicamera.face-effects", qos: .userInitiated)
    private let renderer = OverlayRenderer()
    /// Confined to analysisQueue so network inputs never contain rendered private overlays.
    private let analysisRenderer = OverlayRenderer()
    private let gestureDetector = GestureDetector()
    private let faceDetector = FaceAnchorDetector()
    private let feeder = VirtualCameraFeeder()

    private let snapshotLock = NSLock()
    private var snapshot = SceneSnapshot()
    private var frameCounter: UInt64 = 0
    private var lastPreviewUptime: TimeInterval = 0
    private var lastGestureUptime: TimeInterval = 0
    private var lastNetworkUptime: TimeInterval = 0
    private var gestureInFlight = false
    private var lastFaceUptime = -Double.infinity
    private var networkInFlight = false
    // Protected by snapshotLock and copied into analysis work to reject late callbacks after stop.
    private var runGeneration: UInt64 = 0
    private var runIsActive = false

    var isFeedingVirtualCamera: Bool { feeder.isRunning }

    init(
        configuration: AICameraConfiguration,
        privacyMute: PrivacyMuteState = PrivacyMuteState(),
        runtimeFeatures: RuntimeFeatureState = RuntimeFeatureState(),
        onPreview: @escaping PreviewHandler,
        onGestures: @escaping GestureHandler,
        onFrame: @escaping FrameHandler,
        onError: @escaping ErrorHandler,
        scriptRenderer: OverlayScriptRenderer? = nil,
        agentPresentation: AgentPresentationState? = nil,
        faceAnchors: FaceAnchorState? = nil
    ) {
        self.configuration = configuration
        self.privacyMute = privacyMute
        self.runtimeFeatures = runtimeFeatures
        self.snapshotFeatures = runtimeFeatures.snapshot
        self.onPreview = onPreview
        self.onGestures = onGestures
        self.onFrame = onFrame
        self.onError = onError
        self.scriptRenderer = scriptRenderer
        self.agentPresentation = agentPresentation
        self.faceAnchors = faceAnchors
        super.init()
    }

    func start(publishToVirtualCamera: Bool = true) throws {
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
        if publishToVirtualCamera {
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
        }
        captureQueue.async { [weak self] in
            guard let self, self.currentGeneration() != nil else { return }
            self.session.startRunning()
        }
    }

    @discardableResult
    func stop() -> OSStatus {
        if endRun() {
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            captureQueue.sync {
                if session.isRunning { session.stopRunning() }
                gestureInFlight = false
                if let anchors = faceAnchors, let effect = anchors.requestedGeneration {
                    anchors.apply(nil, generation: effect, capturedAt: ProcessInfo.processInfo.systemUptime)
                }
                networkInFlight = false
            }
        }
        // Retry feeder teardown even after the capture generation already ended. The feeder keeps
        // its CMIO state after a failed stop so a later explicit Stop can complete safely.
        return feeder.stop()
    }

    func update(snapshot: SceneSnapshot, privacy: PrivacyMuteState.Snapshot, features: RuntimeFeatureState.Snapshot) {
        snapshotLock.lock()
        self.snapshot = snapshot
        self.snapshotPrivacy = privacy
        self.snapshotFeatures = features
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
                ? "No physical camera supports the configured frame rate. Select another camera or frame rate in Settings."
                : "The configured camera is not available. Select another camera or System Default."
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

    private struct FormatCandidate {
        let format: AVCaptureDevice.Format
        let range: AVFrameRateRange
        let dimensions: CMVideoDimensions
        let frameRateDistance: Double
        let durationSelection: FrameRateDurationSelection
    }

    private func selectedCamera() -> AVCaptureDevice? {
        DeviceDiscovery.resolveVideoInput(
            requestedID: configuration.capture.videoDeviceID,
            excluding: AICameraVirtualCamera.deviceUID,
            requestedFPS: Double(configuration.capture.framesPerSecond)
        ).device
    }

    private func configure(device: AVCaptureDevice) throws {
        let requestedWidth = configuration.capture.width
        let requestedHeight = configuration.capture.height
        let requestedFPS = Double(configuration.capture.framesPerSecond)
        let candidates = device.formats.compactMap { format -> FormatCandidate? in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dimensions.width > 0,
                  dimensions.height > 0,
                  let match = frameRateMatch(for: format, requestedFPS: requestedFPS) else { return nil }
            return FormatCandidate(
                format: format,
                range: match.range,
                dimensions: dimensions,
                frameRateDistance: match.result.distance,
                durationSelection: match.result.durationSelection
            )
        }
        guard let best = candidates.min(by: { lhs, rhs in
            let leftScore = abs(Int(lhs.dimensions.width) - requestedWidth)
                + abs(Int(lhs.dimensions.height) - requestedHeight)
            let rightScore = abs(Int(rhs.dimensions.width) - requestedWidth)
                + abs(Int(rhs.dimensions.height) - requestedHeight)
            if leftScore != rightScore { return leftScore < rightScore }
            return lhs.frameRateDistance < rhs.frameRateDistance
        }) else {
            throw NSError(
                domain: "AICamera.Video",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "The selected camera does not support \(configuration.capture.framesPerSecond) fps."]
            )
        }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.activeFormat = best.format
        let requestedDuration = CMTime(
            value: 1,
            timescale: CMTimeScale(configuration.capture.framesPerSecond)
        )
        let duration: CMTime
        switch best.durationSelection {
        case .requested:
            duration = requestedDuration
        case .minimumFrameDuration:
            duration = best.range.minFrameDuration
        case .maximumFrameDuration:
            duration = best.range.maxFrameDuration
        }
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    private func frameRateMatch(
        for format: AVCaptureDevice.Format,
        requestedFPS: Double
    ) -> (range: AVFrameRateRange, result: NominalFrameRateMatch)? {
        format.videoSupportedFrameRateRanges.compactMap { range in
            guard let result = NominalFrameRateMatcher.match(
                requestedFPS: requestedFPS,
                minimumFPS: range.minFrameRate,
                maximumFPS: range.maxFrameRate
            ) else { return nil }
            return (range: range, result: result)
        }
        .min { $0.result.distance < $1.result.distance }
    }

    private func currentSnapshot() -> SceneSnapshot {
        snapshotLock.lock()
        defer { snapshotLock.unlock() }
        return runtimeFeatures.filtered(privacyMute.filtered(snapshot, from: snapshotPrivacy), from: snapshotFeatures)
    }

    private func process(_ sampleBuffer: CMSampleBuffer) {
        guard let generation = currentGeneration(),
              let input = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let privacy = privacyMute.snapshot
        let features = runtimeFeatures.snapshot
        frameCounter &+= 1
        let frameID = FrameID(rawValue: frameCounter)
        // The inference path below always uses the clean renderer; only the
        // published frame may carry a script overlay.
        let scriptOverlay = !privacy.isMuted && configuration.overlays.script.enabled
            ? scriptRenderer?.latestFreshOverlay()
            : nil
        guard let output = renderer.render(
            input: input,
            capture: configuration.capture,
            overlay: configuration.overlays,
            snapshot: currentSnapshot(),
            scriptOverlay: scriptOverlay,
            cards: !privacy.isMuted && configuration.overlays.script.enabled ? (agentPresentation?.cards() ?? []) : [],
            cameraLayout: !privacy.isMuted && configuration.overlays.script.enabled ? (agentPresentation?.cameraLayout() ?? .camera) : .camera
        ) else { return }

        guard privacyMute.isCurrent(privacy), runtimeFeatures.snapshot == features else { return }
        if feeder.isRunning, let outgoing = makeSampleBuffer(pixelBuffer: output, source: sampleBuffer) {
            do { _ = try feeder.enqueue(outgoing) }
            catch { onError("Virtual camera feed: \(error.localizedDescription)") }
        }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastPreviewUptime >= 1 / 12, let image = renderer.previewImage(from: output) {
            lastPreviewUptime = uptime
            onPreview(image, privacy, features)
        }
        submitGestureIfNeeded(pixelBuffer: input, frameID: frameID, uptime: uptime, generation: generation)
        submitFaceIfNeeded(pixelBuffer: input, uptime: uptime, generation: generation)
        submitNetworkFrameIfNeeded(pixelBuffer: input, frameID: frameID, uptime: uptime, generation: generation)
    }

    private func submitFaceIfNeeded(pixelBuffer: CVPixelBuffer, uptime: TimeInterval, generation: UInt64) {
        guard configuration.overlays.script.enabled, !privacyMute.snapshot.isMuted,
              let anchors = faceAnchors, let effect = anchors.requestedGeneration,
              uptime - lastFaceUptime >= 1.0 / 8,
              let analysis = anchors.beginAnalysis(generation: effect) else { return }
        lastFaceUptime = uptime
        let output = CGSize(width: configuration.capture.width, height: configuration.capture.height)
        let mirrored = configuration.capture.mirrorVideo
        faceQueue.async { [weak self] in
            defer { anchors.endAnalysis(analysis) }
            guard let self, self.isActive(generation: generation), !self.privacyMute.snapshot.isMuted,
                  anchors.requestedGeneration == effect else { return }
            let anchor = self.faceDetector.detect(in: pixelBuffer, output: output, mirrored: mirrored)
            guard self.isActive(generation: generation), !self.privacyMute.snapshot.isMuted else { return }
            anchors.apply(anchor, generation: effect, capturedAt: uptime)
        }
    }

    private func submitGestureIfNeeded(
        pixelBuffer: CVPixelBuffer,
        frameID: FrameID,
        uptime: TimeInterval,
        generation: UInt64
    ) {
        guard runtimeFeatures.permitsGesture(capturedAt: uptime),
              let stage = configuration.pipeline.videoStages.first(where: { $0.enabled && $0.kind == .handGesture }),
              !gestureInFlight,
              uptime - lastGestureUptime >= 1 / stage.maximumRateHz else { return }
        gestureInFlight = true
        lastGestureUptime = uptime
        let mirrored = configuration.capture.mirrorVideo
        gestureQueue.async { [weak self] in
            guard let self, self.isActive(generation: generation) else { return }
            let observations = self.gestureDetector.detect(in: pixelBuffer, mirrored: mirrored)
            self.captureQueue.async { [weak self] in self?.gestureInFlight = false }
            guard self.isActive(generation: generation), self.runtimeFeatures.permitsGesture(capturedAt: uptime) else { return }
            self.onGestures(observations, frameID, uptime)
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
