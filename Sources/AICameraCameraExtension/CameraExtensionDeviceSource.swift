import CoreMedia
import CoreMediaIO
import CoreVideo
import Foundation
import IOKit.audio
import os

private let cameraExtensionErrorDomain = "ai.kortexa.aicamera.camera-extension"

final class CameraExtensionDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private(set) var sourceStreamSource: CameraExtensionStreamSource!
    private(set) var sinkStreamSource: CameraExtensionStreamSource!

    private let logger = Logger(subsystem: cameraExtensionErrorDomain, category: "device")
    private let extensionRunID = UUID()
    private let stateLock = NSLock()
    private let demandQueue = DispatchQueue(
        label: "ai.kortexa.aicamera.camera-extension.demand",
        qos: .utility
    )
    private let mediaQueue = DispatchQueue(
        label: "ai.kortexa.aicamera.camera-extension.media",
        qos: .userInteractive
    )

    private let streamFormats: [CMIOExtensionStreamFormat]
    private let formatDescriptions: [CMVideoFormatDescription]

    private var selectedFormatIndex = AICameraVirtualCamera.defaultFormatIndex
    private var selectedFrameRate = AICameraVirtualCamera.defaultFrameRate
    private var sourceStartCount = 0
    private var sourceGeneration: UInt64 = 0
    private var sinkClient: CMIOExtensionClient?
    private var sinkBinding: CompanionHostAuthorizer.ProcessBinding?
    private var sinkIsRunning = false
    private var sinkGeneration: UInt64 = 0
    private var consumeIsOutstanding = false
    private var lastFeederFrameHostTime: UInt64 = 0

    // mediaQueue-only state
    private var placeholderTimer: DispatchSourceTimer?
    private var consumeTimer: DispatchSourceTimer?
    private var lastBindingValidationUptime: TimeInterval = 0
    private var lastDemandHeartbeatUptime: TimeInterval = 0
    private var placeholderGenerator: PlaceholderFrameGenerator?
    private var placeholderFormatIndex: Int?

    override init() {
        do {
            let created = try Self.makeFormats()
            streamFormats = created.formats
            formatDescriptions = created.descriptions
        } catch {
            fatalError("Unable to create camera stream formats: \(error.localizedDescription)")
        }

        super.init()

        device = CMIOExtensionDevice(
            localizedName: AICameraVirtualCamera.localizedName,
            deviceID: AICameraVirtualCamera.deviceID,
            legacyDeviceID: AICameraVirtualCamera.deviceUID,
            source: self
        )
        sourceStreamSource = CameraExtensionStreamSource(
            localizedName: "AI Camera Source",
            streamID: AICameraVirtualCamera.sourceStreamID,
            direction: .source,
            formats: streamFormats,
            deviceSource: self
        )
        sinkStreamSource = CameraExtensionStreamSource(
            localizedName: "AI Camera Feeder",
            streamID: AICameraVirtualCamera.sinkStreamID,
            direction: .sink,
            formats: streamFormats,
            deviceSource: self
        )

        do {
            try device.addStream(sourceStreamSource.stream)
            try device.addStream(sinkStreamSource.stream)
        } catch {
            fatalError("Unable to add camera streams: \(error.localizedDescription)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [
            .deviceTransportType,
            .deviceModel,
            .deviceCanBeDefaultInputDevice,
            AICameraMediaDemandState.cameraDemandProperty,
        ]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let result = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            result.transportType = kIOAudioDeviceTransportTypeVirtual
        }
        if properties.contains(.deviceModel) {
            result.model = AICameraVirtualCamera.model
        }
        if properties.contains(.deviceCanBeDefaultInputDevice) {
            result.setPropertyState(
                CMIOExtensionPropertyState(value: NSNumber(value: true)),
                forProperty: .deviceCanBeDefaultInputDevice
            )
        }
        if properties.contains(AICameraMediaDemandState.cameraDemandProperty),
           let state = cameraDemandPropertyState() {
            result.setPropertyState(
                state,
                forProperty: AICameraMediaDemandState.cameraDemandProperty
            )
        }
        return result
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        // This virtual device currently has no writable device-level properties.
    }

    var activeFormatIndex: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return selectedFormatIndex
    }

    var frameDuration: CMTime {
        stateLock.lock()
        defer { stateLock.unlock() }
        return .aicameraFrameDuration(rate: selectedFrameRate)
    }

    func setActiveFormatIndex(
        _ index: Int,
        requestedBy direction: CMIOExtensionStream.Direction
    ) throws {
        guard AICameraVirtualCamera.formats.indices.contains(index) else {
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported camera format index \(index)"]
            )
        }
        stateLock.lock()
        if direction == .source, sinkIsRunning, selectedFormatIndex != index {
            stateLock.unlock()
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "The active feeder controls the virtual camera format"]
            )
        }
        let changed = selectedFormatIndex != index
        selectedFormatIndex = index
        stateLock.unlock()
        guard changed else { return }
        notifyStreamConfigurationChanged()
        mediaQueue.async { [weak self] in self?.restartPlaceholderTimerIfNeeded() }
    }

    func setFrameDuration(
        _ duration: CMTime,
        requestedBy direction: CMIOExtensionStream.Direction
    ) throws {
        guard let rate = AICameraVirtualCamera.supportedFrameRates.first(where: {
            CMTimeCompare(duration, .aicameraFrameDuration(rate: $0)) == 0
        }) else {
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Only 15, 30, and 60 fps are supported"]
            )
        }
        stateLock.lock()
        if direction == .source, sinkIsRunning, selectedFrameRate != rate {
            stateLock.unlock()
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "The active feeder controls the virtual camera frame rate"]
            )
        }
        let changed = selectedFrameRate != rate
        selectedFrameRate = rate
        stateLock.unlock()
        guard changed else { return }
        notifyStreamConfigurationChanged()
        mediaQueue.async { [weak self] in self?.restartPlaceholderTimerIfNeeded() }
    }

    func authorizeSink(
        client: CMIOExtensionClient
    ) -> CompanionHostAuthorizer.ProcessBinding? {
        // Only the same-team companion host may write processed frames. CoreMediaIO reports
        // unsandboxed clients as `unknown`, so validate the live client PID's code signature too.
        let decision = CompanionHostAuthorizer.evaluate(pid: client.pid)
        guard decision.isAuthorized, let binding = decision.binding else {
            let reportedIDMatches = client.signingID == AICameraVirtualCamera.hostBundleIdentifier
            logger.error(
                "Rejected feeder client pid \(client.pid, privacy: .public), reported ID matched: \(reportedIDMatches, privacy: .public): \(decision.reason, privacy: .public)"
            )
            return nil
        }
        stateLock.lock()
        let hasActiveFeeder = sinkIsRunning && sinkClient != nil
        stateLock.unlock()
        guard !hasActiveFeeder else {
            logger.error("Rejected an additional feeder while another feeder is active")
            return nil
        }
        logger.info(
            "Authorized feeder client pid \(client.pid, privacy: .public): \(decision.reason, privacy: .public)"
        )
        return binding
    }

    func startStream(
        direction: CMIOExtensionStream.Direction,
        client: CMIOExtensionClient?,
        binding: CompanionHostAuthorizer.ProcessBinding?
    ) throws {
        switch direction {
        case .source:
            stateLock.lock()
            sourceStartCount += 1
            let shouldStartTimer = sourceStartCount == 1
            if shouldStartTimer { sourceGeneration &+= 1 }
            let generation = sourceGeneration
            stateLock.unlock()
            publishCameraDemand()
            if shouldStartTimer {
                mediaQueue.async { [weak self] in
                    self?.startPlaceholderTimer(generation: generation)
                }
            }
        case .sink:
            guard let client, let binding,
                  CompanionHostAuthorizer.bindingIsCurrent(binding) else {
                throw NSError(
                    domain: cameraExtensionErrorDomain,
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "The feeder sink has no current authorized client"]
                )
            }
            stateLock.lock()
            guard !sinkIsRunning, sinkClient == nil, sinkBinding == nil else {
                stateLock.unlock()
                throw NSError(
                    domain: cameraExtensionErrorDomain,
                    code: 7,
                    userInfo: [NSLocalizedDescriptionKey: "Another feeder sink is already active"]
                )
            }
            sinkGeneration &+= 1
            let generation = sinkGeneration
            sinkClient = client
            sinkBinding = binding
            sinkIsRunning = true
            lastFeederFrameHostTime = 0
            stateLock.unlock()
            mediaQueue.async { [weak self] in self?.startConsumeTimer(generation: generation) }
        @unknown default:
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported camera stream direction"]
            )
        }
    }

    func stopStream(direction: CMIOExtensionStream.Direction) {
        switch direction {
        case .source:
            stateLock.lock()
            let hadSourceClient = sourceStartCount > 0
            sourceStartCount = max(0, sourceStartCount - 1)
            let shouldStopTimer = hadSourceClient && sourceStartCount == 0
            if shouldStopTimer { sourceGeneration &+= 1 }
            let generation = sourceGeneration
            stateLock.unlock()
            publishCameraDemand()
            if shouldStopTimer {
                mediaQueue.async { [weak self] in
                    self?.stopPlaceholderTimer(generation: generation)
                }
            }
        case .sink:
            stateLock.lock()
            sinkGeneration &+= 1
            let generation = sinkGeneration
            sinkIsRunning = false
            sinkClient = nil
            sinkBinding = nil
            lastFeederFrameHostTime = 0
            stateLock.unlock()
            mediaQueue.async { [weak self] in self?.stopConsumeTimer(generation: generation) }
        @unknown default:
            break
        }
    }

    private func publishCameraDemand() {
        demandQueue.async { [weak self] in
            guard let self,
                  let state = self.cameraDemandPropertyState() else { return }
            self.device.notifyPropertiesChanged([
                AICameraMediaDemandState.cameraDemandProperty: state,
            ])
        }
    }

    private func cameraDemandPropertyState() -> CMIOExtensionPropertyState<AnyObject>? {
        stateLock.lock()
        let generation = sourceGeneration
        let sourceClientCount = sourceStartCount
        stateLock.unlock()
        let snapshot = AICameraCameraDemandSnapshot(
            extensionRunID: extensionRunID,
            generation: generation,
            sourceClientCount: sourceClientCount,
            updatedAt: Date()
        )
        guard let data = AICameraMediaDemandState.encodeCameraSnapshot(snapshot) else {
            return nil
        }
        return CMIOExtensionPropertyState(
            value: data as NSData,
            attributes: CMIOExtensionPropertyAttributes<AnyObject>.readOnlyPropertyAttribute
        )
    }

    private func startConsumeTimer(generation: UInt64) {
        // Start/stop callbacks can arrive from different extension threads. Ignore a stale queued
        // transition so it cannot cancel the timer for a newer sink client.
        guard isActiveSinkGeneration(generation) else { return }
        consumeTimer?.cancel()
        consumeTimer = nil
        consumeIsOutstanding = false
        lastBindingValidationUptime = 0
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: mediaQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            self?.consumeOneBufferIfAvailable(generation: generation)
        }
        consumeTimer = timer
        timer.activate()
    }

    private func stopConsumeTimer(generation: UInt64) {
        stateLock.lock()
        let isCurrentStoppedGeneration = !sinkIsRunning && sinkGeneration == generation
        stateLock.unlock()
        guard isCurrentStoppedGeneration else { return }
        consumeTimer?.cancel()
        consumeTimer = nil
        consumeIsOutstanding = false
        lastBindingValidationUptime = 0
    }

    private func consumeOneBufferIfAvailable(generation: UInt64) {
        stateLock.lock()
        let client = sinkIsRunning && sinkGeneration == generation ? sinkClient : nil
        let binding = sinkIsRunning && sinkGeneration == generation ? sinkBinding : nil
        stateLock.unlock()
        guard let client, let binding else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastBindingValidationUptime >= 0.25 {
            lastBindingValidationUptime = now
            guard CompanionHostAuthorizer.bindingIsCurrent(binding) else {
                revokeSinkAuthorization(generation: generation)
                return
            }
        }
        guard !consumeIsOutstanding else { return }

        consumeIsOutstanding = true
        sinkStreamSource.stream.consumeSampleBuffer(from: client) { [weak self] sampleBuffer, sequenceNumber, discontinuity, hasMore, error in
            guard let self else { return }
            self.mediaQueue.async {
                guard self.isActiveSinkGeneration(generation) else { return }
                self.consumeIsOutstanding = false
                if let sampleBuffer {
                    guard CompanionHostAuthorizer.bindingIsCurrent(binding) else {
                        self.revokeSinkAuthorization(generation: generation)
                        return
                    }
                    self.forward(
                        sampleBuffer,
                        sequenceNumber: sequenceNumber,
                        discontinuity: discontinuity
                    )
                } else if let error {
                    self.logger.debug("Sink consume returned no frame: \(error.localizedDescription, privacy: .public)")
                }
                if hasMore {
                    self.consumeOneBufferIfAvailable(generation: generation)
                }
            }
        }
    }

    private func revokeSinkAuthorization(generation: UInt64) {
        stateLock.lock()
        guard sinkIsRunning && sinkGeneration == generation else {
            stateLock.unlock()
            return
        }
        sinkGeneration &+= 1
        sinkIsRunning = false
        sinkClient = nil
        sinkBinding = nil
        lastFeederFrameHostTime = 0
        stateLock.unlock()
        consumeTimer?.cancel()
        consumeTimer = nil
        consumeIsOutstanding = false
        lastBindingValidationUptime = 0
        logger.error("Revoked a feeder whose process execution identity changed")
    }

    private func isActiveSinkGeneration(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sinkIsRunning && sinkGeneration == generation
    }

    private func forward(
        _ sampleBuffer: CMSampleBuffer,
        sequenceNumber: UInt64,
        discontinuity: CMIOExtensionStream.DiscontinuityFlags
    ) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nowNanos = Self.nanoseconds(for: now)
        defer {
            sinkStreamSource.stream.notifyScheduledOutputChanged(
                CMIOExtensionScheduledOutput(
                    sequenceNumber: sequenceNumber,
                    hostTimeInNanoseconds: nowNanos
                )
            )
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let index = activeFormatIndex
        guard AICameraVirtualCamera.formats[index].supports(imageBuffer) else {
            logger.error("Dropping a feeder frame that does not match the active BGRA format")
            return
        }

        stateLock.lock()
        lastFeederFrameHostTime = nowNanos
        let hasSourceClient = sourceStartCount > 0
        stateLock.unlock()
        guard hasSourceClient else { return }

        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let captureNanos = presentationTime.isValid ? Self.nanoseconds(for: presentationTime) : nowNanos
        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: discontinuity,
            hostTimeInNanoseconds: captureNanos
        )
    }

    private func startPlaceholderTimer(generation: UInt64) {
        stateLock.lock()
        let isCurrentRunningGeneration = sourceStartCount > 0 && sourceGeneration == generation
        stateLock.unlock()
        guard isCurrentRunningGeneration else { return }
        startPlaceholderTimer()
    }

    private func startPlaceholderTimer() {
        guard placeholderTimer == nil else { return }
        let duration = frameDuration
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: mediaQueue)
        timer.schedule(
            deadline: .now(),
            repeating: duration.seconds,
            leeway: .milliseconds(1)
        )
        timer.setEventHandler { [weak self] in self?.sendPlaceholderIfNeeded() }
        placeholderTimer = timer
        timer.activate()
    }

    private func stopPlaceholderTimer(generation: UInt64) {
        stateLock.lock()
        let isCurrentStoppedGeneration = sourceStartCount == 0 && sourceGeneration == generation
        stateLock.unlock()
        guard isCurrentStoppedGeneration else { return }
        stopPlaceholderTimer()
    }

    private func stopPlaceholderTimer() {
        placeholderTimer?.cancel()
        placeholderTimer = nil
        placeholderGenerator = nil
        placeholderFormatIndex = nil
    }

    private func restartPlaceholderTimerIfNeeded() {
        stateLock.lock()
        let hasSourceClient = sourceStartCount > 0
        stateLock.unlock()
        guard hasSourceClient else {
            stopPlaceholderTimer()
            return
        }
        guard placeholderTimer != nil else { return }
        stopPlaceholderTimer()
        startPlaceholderTimer()
    }

    private func sendPlaceholderIfNeeded() {
        stateLock.lock()
        let hasSourceClient = sourceStartCount > 0
        let lastFrame = lastFeederFrameHostTime
        stateLock.unlock()
        guard hasSourceClient else { return }

        let uptime = ProcessInfo.processInfo.systemUptime
        if uptime - lastDemandHeartbeatUptime >= 1 {
            lastDemandHeartbeatUptime = uptime
            publishCameraDemand()
        }

        let now = CMClockGetTime(CMClockGetHostTimeClock())
        let nowNanos = Self.nanoseconds(for: now)
        let staleAfterNanos = max(
            UInt64(250_000_000),
            UInt64(max(0, frameDuration.seconds) * 3 * 1_000_000_000)
        )
        if lastFrame != 0, nowNanos >= lastFrame, nowNanos - lastFrame < staleAfterNanos {
            return
        }

        let index = activeFormatIndex
        if placeholderGenerator == nil || placeholderFormatIndex != index {
            placeholderGenerator = PlaceholderFrameGenerator(
                format: AICameraVirtualCamera.formats[index],
                formatDescription: formatDescriptions[index]
            )
            placeholderFormatIndex = index
        }
        guard let sampleBuffer = placeholderGenerator?.makeSampleBuffer(
            presentationTimeStamp: now,
            frameDuration: frameDuration
        ) else {
            return
        }
        sourceStreamSource.stream.send(
            sampleBuffer,
            discontinuity: [],
            hostTimeInNanoseconds: nowNanos
        )
    }

    private func notifyStreamConfigurationChanged() {
        let index = activeFormatIndex
        let duration = frameDuration
        let durationDictionary = CMTimeCopyAsDictionary(duration, allocator: kCFAllocatorDefault)
        let changes: [CMIOExtensionProperty: CMIOExtensionPropertyState<AnyObject>] = [
            .streamActiveFormatIndex: CMIOExtensionPropertyState(value: NSNumber(value: index)),
            .streamFrameDuration: CMIOExtensionPropertyState(value: durationDictionary),
        ]
        sourceStreamSource.stream.notifyPropertiesChanged(changes)
        sinkStreamSource.stream.notifyPropertiesChanged(changes)
    }

    private static func makeFormats() throws -> (
        formats: [CMIOExtensionStreamFormat],
        descriptions: [CMVideoFormatDescription]
    ) {
        var formats: [CMIOExtensionStreamFormat] = []
        var descriptions: [CMVideoFormatDescription] = []
        let durations = AICameraVirtualCamera.supportedFrameRates.map {
            CMTime.aicameraFrameDuration(rate: $0)
        }
        for format in AICameraVirtualCamera.formats {
            var description: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(
                allocator: kCFAllocatorDefault,
                codecType: AICameraVirtualCamera.pixelFormat,
                width: format.width,
                height: format.height,
                extensions: nil,
                formatDescriptionOut: &description
            )
            guard status == noErr, let description else {
                throw NSError(
                    domain: cameraExtensionErrorDomain,
                    code: Int(status),
                    userInfo: [NSLocalizedDescriptionKey: "Unable to create \(format.width)x\(format.height) BGRA format"]
                )
            }
            descriptions.append(description)
            formats.append(
                CMIOExtensionStreamFormat(
                    formatDescription: description,
                    maxFrameDuration: .aicameraFrameDuration(rate: 15),
                    minFrameDuration: .aicameraFrameDuration(rate: 60),
                    validFrameDurations: durations
                )
            )
        }
        return (formats, descriptions)
    }

    private static func nanoseconds(for time: CMTime) -> UInt64 {
        guard time.isNumeric else { return 0 }
        let scaled = CMTimeConvertScale(time, timescale: 1_000_000_000, method: .default)
        return scaled.value > 0 ? UInt64(scaled.value) : 0
    }
}

final class CameraExtensionStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!

    let formats: [CMIOExtensionStreamFormat]
    private let direction: CMIOExtensionStream.Direction
    private weak var deviceSource: CameraExtensionDeviceSource?
    private let clientLock = NSLock()
    private var approvedSinkClient: CMIOExtensionClient?
    private var approvedSinkBinding: CompanionHostAuthorizer.ProcessBinding?
    private var sinkAuthorizationInProgress = false
    private var sinkAuthorizationGeneration: UInt64 = 0

    init(
        localizedName: String,
        streamID: UUID,
        direction: CMIOExtensionStream.Direction,
        formats: [CMIOExtensionStreamFormat],
        deviceSource: CameraExtensionDeviceSource
    ) {
        self.formats = formats
        self.direction = direction
        self.deviceSource = deviceSource
        super.init()
        stream = CMIOExtensionStream(
            localizedName: localizedName,
            streamID: streamID,
            direction: direction,
            clockType: .hostTime,
            source: self
        )
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        var properties: Set<CMIOExtensionProperty> = [
            .streamActiveFormatIndex,
            .streamFrameDuration,
            .streamMaxFrameDuration,
        ]
        if direction == .sink {
            properties.formUnion([
                .streamSinkBufferQueueSize,
                .streamSinkBuffersRequiredForStartup,
                .streamSinkBufferUnderrunCount,
                .streamSinkEndOfData,
            ])
        }
        return properties
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        guard let deviceSource else {
            throw NSError(
                domain: cameraExtensionErrorDomain,
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "The camera device is no longer available"]
            )
        }
        let result = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) {
            result.activeFormatIndex = deviceSource.activeFormatIndex
        }
        if properties.contains(.streamFrameDuration) {
            result.frameDuration = deviceSource.frameDuration
        }
        if properties.contains(.streamMaxFrameDuration) {
            result.maxFrameDuration = .aicameraFrameDuration(rate: 15)
        }
        if direction == .sink {
            if properties.contains(.streamSinkBufferQueueSize) {
                result.sinkBufferQueueSize = 1
            }
            if properties.contains(.streamSinkBuffersRequiredForStartup) {
                result.sinkBuffersRequiredForStartup = 1
            }
            if properties.contains(.streamSinkBufferUnderrunCount) {
                result.sinkBufferUnderrunCount = 0
            }
            if properties.contains(.streamSinkEndOfData) {
                result.sinkEndOfData = 0
            }
        }
        return result
    }

    func setStreamProperties(_ properties: CMIOExtensionStreamProperties) throws {
        if let index = properties.activeFormatIndex {
            try deviceSource?.setActiveFormatIndex(index, requestedBy: direction)
        }
        if let duration = properties.frameDuration {
            try deviceSource?.setFrameDuration(duration, requestedBy: direction)
        }
    }

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        guard direction == .sink else { return true }
        clientLock.lock()
        guard approvedSinkClient == nil, !sinkAuthorizationInProgress else {
            clientLock.unlock()
            return false
        }
        sinkAuthorizationGeneration &+= 1
        let generation = sinkAuthorizationGeneration
        sinkAuthorizationInProgress = true
        clientLock.unlock()

        let binding = deviceSource?.authorizeSink(client: client)
        clientLock.lock()
        guard sinkAuthorizationGeneration == generation,
              sinkAuthorizationInProgress else {
            clientLock.unlock()
            return false
        }
        sinkAuthorizationInProgress = false
        guard let binding, approvedSinkClient == nil else {
            clientLock.unlock()
            return false
        }
        approvedSinkClient = client
        approvedSinkBinding = binding
        clientLock.unlock()
        return true
    }

    func startStream() throws {
        clientLock.lock()
        defer { clientLock.unlock() }
        let client = approvedSinkClient
        let binding = approvedSinkBinding
        approvedSinkClient = nil
        approvedSinkBinding = nil
        try deviceSource?.startStream(
            direction: direction,
            client: client,
            binding: binding
        )
    }

    func stopStream() throws {
        clientLock.lock()
        sinkAuthorizationGeneration &+= 1
        approvedSinkClient = nil
        approvedSinkBinding = nil
        sinkAuthorizationInProgress = false
        deviceSource?.stopStream(direction: direction)
        clientLock.unlock()
    }
}
