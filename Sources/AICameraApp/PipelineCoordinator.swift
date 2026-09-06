import AICameraCore
import Foundation

enum SpeechPlaybackEvent: Sendable {
    case wav(speechID: UUID, data: Data)
    case beginPCM(speechID: UUID, sampleRate: Int, channels: Int)
    case pcm(speechID: UUID, data: Data)
    case finishPCM(speechID: UUID)
    case stop(speechID: UUID?)
}

struct FrameAnalysisPacket: Sendable {
    let frameID: FrameID
    let capturedAt: Date
    let jpegData: Data
    let width: Int
    let height: Int
}

actor PipelineCoordinator {
    private enum ConversationInput: Sendable {
        case text(String)
    }

    typealias SnapshotHandler = @Sendable (SceneSnapshot) -> Void
    typealias SpeechHandler = @Sendable (SpeechPlaybackEvent) async -> Bool
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: AICameraConfiguration
    private let scene = SceneState()
    private let privacyMute: PrivacyMuteState
    private let onGestureControl: @Sendable (GestureControlAction) -> Void
    private let onGestureControlWithTimestamp: (@Sendable (GestureControlAction, TimeInterval) -> Void)?
    private var gestureControls = GestureControlGate()
    private let factory: AdapterFactory
    private let builtinDetectionClient: (any DetectionClient)?
    private let builtinTranslationClient: (any TranslationClient)?
    private let builtinTranscriptionClient: (any TranscriptionClient)?
    private let onSnapshot: SnapshotHandler
    private let onSnapshotWithPrivacy: (@Sendable (SceneSnapshot, PrivacyMuteState.Snapshot) -> Void)?
    private let onSpeech: SpeechHandler
    private let onSpeechWithPrivacy: (@Sendable (SpeechPlaybackEvent, PrivacyMuteState.Snapshot) async -> Bool)?
    private let onError: ErrorHandler

    private var runningStages = Set<String>()
    private var stageTasks: [String: Task<Void, Never>] = [:]
    private var pendingPackets: [String: FrameAnalysisPacket] = [:]
    private var isRunning = true
    private var lastStageStart: [String: Date] = [:]
    private var transcriptionTask: Task<Void, Never>?
    private var pendingUtterance: (utterance: AudioUtterance, privacy: PrivacyMuteState.Snapshot)?
    private var transcriptionGeneration: UInt64 = 0
    private var realtimeTranscriptionActive = false
    private var realtimeTranscriptRevisions: [RealtimeTranscriptSource: UInt64] = [:]
    private var realtimeTranslationTask: Task<Void, Never>?
    private var pendingRealtimeTranslation: (event: TranscriptEvent, source: RealtimeTranscriptSource, revision: UInt64, privacy: PrivacyMuteState.Snapshot)?
    private var conversationTask: Task<Void, Never>?
    private var pendingConversationInput: ConversationInput?
    private var conversationGeneration: UInt64 = 0
    private var lastGestureResponse = Date.distantPast
    private var lastObservedGestureKind: GestureKind?
    private var wakePhraseGate = WakePhraseGate()
    private var expiryTask: Task<Void, Never>?

    init(
        configuration: AICameraConfiguration,
        secrets: any SecretResolver,
        privacyMute: PrivacyMuteState = PrivacyMuteState(),
        onGestureControl: @escaping @Sendable (GestureControlAction) -> Void = { _ in },
        onGestureControlWithTimestamp: (@Sendable (GestureControlAction, TimeInterval) -> Void)? = nil,
        builtinDetectionClient: (any DetectionClient)? = nil,
        builtinTranslationClient: (any TranslationClient)? = nil,
        builtinTranscriptionClient: (any TranscriptionClient)? = nil,
        onSnapshotWithPrivacy: (@Sendable (SceneSnapshot, PrivacyMuteState.Snapshot) -> Void)? = nil,
        onSnapshot: @escaping SnapshotHandler = { _ in },
        onSpeechWithPrivacy: (@Sendable (SpeechPlaybackEvent, PrivacyMuteState.Snapshot) async -> Bool)? = nil,
        onSpeech: @escaping SpeechHandler = { _ in false },
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.privacyMute = privacyMute
        self.onGestureControl = onGestureControl
        self.onGestureControlWithTimestamp = onGestureControlWithTimestamp
        self.factory = AdapterFactory(
            secrets: secrets,
            privacy: PrivacyGate(configuration: configuration.privacy)
        )
        self.builtinDetectionClient = builtinDetectionClient
        self.builtinTranslationClient = builtinTranslationClient
        self.builtinTranscriptionClient = builtinTranscriptionClient
        self.onSnapshot = onSnapshot
        self.onSnapshotWithPrivacy = onSnapshotWithPrivacy
        self.onSpeech = onSpeech
        self.onSpeechWithPrivacy = onSpeechWithPrivacy
        self.onError = onError
    }

    func started() async {
        guard isRunning else { return }
        await scene.setStatus("AI Camera")
        await publish()
        guard isRunning else { return }
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.expireOverlayResults()
            }
        }
    }

    func stop() async {
        isRunning = false
        cancelRealtimeCaptions()
        transcriptionGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pendingUtterance = nil
        conversationGeneration &+= 1
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
        _ = await stopSpeech(nil)
        wakePhraseGate.reset()
        expiryTask?.cancel()
        expiryTask = nil
        for task in stageTasks.values { task.cancel() }
        stageTasks.removeAll()
        runningStages.removeAll()
        pendingPackets.removeAll()
    }

    func submit(frame packet: FrameAnalysisPacket) {
        guard isRunning else { return }
        for stage in configuration.pipeline.videoStages where stage.enabled && stage.kind != .handGesture {
            let minimumInterval = 1 / stage.maximumRateHz
            if let last = lastStageStart[stage.id], packet.capturedAt.timeIntervalSince(last) < minimumInterval {
                continue
            }
            if runningStages.contains(stage.id) {
                pendingPackets[stage.id] = packet
            } else {
                start(stage: stage, packet: packet)
            }
        }
    }

    func submitRealtimeTranscript(source: RealtimeTranscriptSource, text: String, isFinal: Bool) async {
        let privacy = privacyMute.snapshot
        let visible = source == .local ? configuration.overlays.showTranscript : configuration.overlays.showAgentResponse
        guard isRunning, !Task.isCancelled, visible, privacyMute.permitsSpeech(privacy) else { return }
        realtimeTranscriptRevisions[source, default: 0] &+= 1
        let revision = realtimeTranscriptRevisions[source, default: 0]
        let event = TranscriptEvent(text: text, mode: isFinal ? .final : .partial)
        await applyRealtimeCaption(event, source: source, privacy: privacy)
        guard isRunning, !Task.isCancelled, revision == realtimeTranscriptRevisions[source],
              isFinal, configuration.pipeline.translation.enabled else { return }
        // Translation must not hold the Realtime event consumer while PCM/control events arrive.
        // Retain one running translation and replace the single pending finalized transcript.
        pendingRealtimeTranslation = (event, source, revision, privacy)
        startRealtimeTranslationIfNeeded()
    }

    private func applyRealtimeCaption(_ event: TranscriptEvent, source: RealtimeTranscriptSource, privacy: PrivacyMuteState.Snapshot) async {
        guard privacyMute.permitsSpeech(privacy) else { return }
        switch source {
        case .local: await scene.applyTranscript(event, privacyGeneration: privacy.generation)
        case .remote: await scene.applyAgentResponse(event.text, privacyGeneration: privacy.generation)
        }
        await publish()
    }

    /// Talk can stop while camera processing remains active. Normal completion keeps final
    /// translation work; explicit cancellation retires it before the transport closes.
    func cancelRealtimeCaptions() {
        realtimeTranscriptRevisions[.local, default: 0] &+= 1
        realtimeTranscriptRevisions[.remote, default: 0] &+= 1
        realtimeTranslationTask?.cancel()
        // Keep the active task reference until its completion so the next turn cannot overlap it.
        pendingRealtimeTranslation = nil
    }

    private func startRealtimeTranslationIfNeeded() {
        guard isRunning, realtimeTranslationTask == nil,
              let pending = pendingRealtimeTranslation else { return }
        pendingRealtimeTranslation = nil
        realtimeTranslationTask = Task { [weak self] in
            guard let self else { return }
            let privacy = pending.privacy
            let displayed = self.privacyMute.permitsSpeech(privacy)
                ? await self.translated(pending.event) : pending.event
            await self.finishRealtimeTranslation(displayed, source: pending.source, revision: pending.revision, privacy: privacy)
        }
    }

    private func finishRealtimeTranslation(_ event: TranscriptEvent, source: RealtimeTranscriptSource, revision: UInt64, privacy: PrivacyMuteState.Snapshot) async {
        if isRunning, !Task.isCancelled, privacyMute.permitsSpeech(privacy), revision == realtimeTranscriptRevisions[source] {
            await applyRealtimeCaption(event, source: source, privacy: privacy)
        }
        realtimeTranslationTask = nil
        startRealtimeTranslationIfNeeded()
    }

    func submit(gestures: [GestureObservation], frameID: FrameID, capturedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) async {
        guard isRunning else { return }
        if let action = gestureControls.observe(gestures, capturedAt: capturedAt, now: ProcessInfo.processInfo.systemUptime) {
            if let onGestureControlWithTimestamp { onGestureControlWithTimestamp(action, capturedAt) }
            else { onGestureControl(action) }
        }
        _ = await scene.applyGestures(gestures, frameID: frameID)
        await publish()

        let conversation = configuration.pipeline.conversation
        guard let gesture = gestures.first(where: { $0.kind != .unknown && $0.confidence >= 0.4 }) else {
            lastObservedGestureKind = nil
            return
        }
        let isNewGesture = gesture.kind != lastObservedGestureKind
        lastObservedGestureKind = gesture.kind
        guard !privacyMute.snapshot.isMuted, conversation.enabled, !conversation.realtimeEnabled, !realtimeTranscriptionActive,
              conversation.respondToGestures,
              isNewGesture,
              Date().timeIntervalSince(lastGestureResponse) >= conversation.gestureCooldownSeconds else { return }
        lastGestureResponse = Date()
        let description = gesture.kind.rawValue
        enqueueConversation(.text("The user made a \(description) gesture. Acknowledge it briefly and respond appropriately."))
    }

    func submit(utterance: AudioUtterance) {
        let privacy = privacyMute.snapshot
        let conversation = configuration.pipeline.conversation
        guard isRunning, privacyMute.permitsSpeech(privacy), conversation.transcriptionEnabled, !realtimeTranscriptionActive else { return }
        if transcriptionTask != nil {
            if conversation.activationMode == .alwaysListening || pendingUtterance == nil {
                // Always-listening favors the latest ambient window. Wake mode preserves the first
                // pending window so a command immediately after a wake-only window cannot be
                // overwritten while the wake transcription is still in flight.
                pendingUtterance = (utterance, privacy)
            }
            return
        }
        startTranscription(utterance, privacy: privacy)
    }

    func setRealtimeTranscriptionActive(_ active: Bool) {
        realtimeTranscriptionActive = active
        guard active else { return }
        cancelRealtimeCaptions()
        // The explicitly armed Realtime turn owns conversation generation until it closes.
        conversationGeneration &+= 1
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
        wakePhraseGate.reset()
        transcriptionGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pendingUtterance = nil
    }

    @discardableResult
    func bargeIn() async -> Bool {
        guard configuration.pipeline.conversation.bargeIn,
              conversationTask != nil else { return false }
        conversationGeneration &+= 1
        let generation = conversationGeneration
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
        _ = await stopSpeech(nil)
        guard generation == conversationGeneration else { return true }
        await scene.applyAgentResponse(nil)
        await publish()
        return true
    }

    private func start(stage: VideoStageConfiguration, packet: FrameAnalysisPacket) {
        guard isRunning else { return }
        runningStages.insert(stage.id)
        lastStageStart[stage.id] = packet.capturedAt
        stageTasks[stage.id] = Task { [weak self] in
            await self?.perform(stage: stage, packet: packet)
        }
    }

    private func perform(stage: VideoStageConfiguration, packet: FrameAnalysisPacket) async {
        defer { finish(stage: stage) }
        guard isRunning else { return }
        guard Date().timeIntervalSince(packet.capturedAt) * 1_000 <= Double(stage.maximumFrameAgeMilliseconds) else { return }
        do {
            switch stage.kind {
            case .objectDetection:
                let endpoint = stage.endpointID.flatMap { endpointID in
                    configuration.endpoints.first(where: { $0.id == endpointID })
                }
                let confidence = stage.options["confidence"]?.numberValue
                    ?? endpoint?.options["confidence"]?.numberValue
                    ?? 0.25
                let client: any DetectionClient
                if stage.options["provider"]?.stringValue == "builtin" {
                    guard let builtinDetectionClient else {
                        throw LocalDetectionError.modelUnavailable
                    }
                    client = builtinDetectionClient
                } else {
                    guard let endpoint else { return }
                    client = try factory.detection(for: endpoint)
                }
                let detections = try await client.detect(.init(
                    jpegData: packet.jpegData,
                    imageWidth: packet.width,
                    imageHeight: packet.height,
                    confidence: confidence
                ))
                try Task.checkCancellation()
                guard isFresh(packet, for: stage) else { return }
                _ = await scene.applyDetections(detections, frameID: packet.frameID)
                await publish()
            case .visionLanguage:
                guard let endpointID = stage.endpointID,
                      let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
                let client = try factory.vision(for: endpoint)
                let summary = try await client.analyze(.init(
                    jpegData: packet.jpegData,
                    prompt: stage.prompt ?? "Describe the visible scene briefly."
                ))
                try Task.checkCancellation()
                guard isFresh(packet, for: stage) else { return }
                _ = await scene.applyVisionSummary(summary, frameID: packet.frameID)
                await publish()
            case .handGesture:
                break
            }
        } catch is CancellationError {
            return
        } catch {
            onError("\(stage.id): \(error.localizedDescription)")
        }
    }

    private enum LocalDetectionError: LocalizedError {
        case modelUnavailable

        var errorDescription: String? { "The built-in object detection model is not available." }
    }

    private func finish(stage: VideoStageConfiguration) {
        stageTasks.removeValue(forKey: stage.id)
        runningStages.remove(stage.id)
        guard isRunning else { return }
        if let pending = pendingPackets.removeValue(forKey: stage.id) {
            let minimumInterval = 1 / stage.maximumRateHz
            let rawDelay = minimumInterval - Date().timeIntervalSince(lastStageStart[stage.id] ?? .distantPast)
            let delay = min(100, max(0, rawDelay.isFinite ? rawDelay : 0))
            Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard !Task.isCancelled else { return }
                await self?.startPending(stage: stage, packet: pending)
            }
        }
    }

    private func startPending(stage: VideoStageConfiguration, packet: FrameAnalysisPacket) {
        guard !runningStages.contains(stage.id) else {
            pendingPackets[stage.id] = packet
            return
        }
        start(stage: stage, packet: packet)
    }

    private func startTranscription(_ utterance: AudioUtterance, privacy: PrivacyMuteState.Snapshot) {
        guard isRunning, privacyMute.permitsSpeech(privacy) else { return }
        transcriptionGeneration &+= 1
        let generation = transcriptionGeneration
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            await self.runTranscription(utterance: utterance, privacy: privacy)
            await self.finishTranscription(generation: generation)
        }
    }

    private func finishTranscription(generation: UInt64) {
        guard generation == transcriptionGeneration else { return }
        transcriptionTask = nil
        guard isRunning, let pending = pendingUtterance else {
            pendingUtterance = nil
            return
        }
        pendingUtterance = nil
        startTranscription(pending.utterance, privacy: pending.privacy)
    }

    private func enqueueConversation(_ input: ConversationInput) {
        guard isRunning, configuration.pipeline.conversation.enabled else { return }
        var stopSpeechFirst = false
        if conversationTask != nil {
            if configuration.pipeline.conversation.bargeIn {
                conversationGeneration &+= 1
                conversationTask?.cancel()
                conversationTask = nil
                pendingConversationInput = nil
                stopSpeechFirst = true
            } else {
                // Preserve at most the latest pending turn while the current turn completes.
                pendingConversationInput = input
                return
            }
        }
        startConversation(input, stopSpeechFirst: stopSpeechFirst)
    }

    private func startConversation(
        _ input: ConversationInput,
        stopSpeechFirst: Bool = false
    ) {
        guard isRunning else { return }
        conversationGeneration &+= 1
        let generation = conversationGeneration
        let privacy = privacyMute.snapshot
        conversationTask = Task { [weak self] in
            guard let self else { return }
            if stopSpeechFirst {
                _ = await self.stopSpeech(nil)
                guard !Task.isCancelled else {
                    await self.finishConversation(generation: generation)
                    return
                }
            }
            switch input {
            case let .text(text):
                await self.runAgent(userText: text, privacy: privacy)
            }
            await self.finishConversation(generation: generation)
        }
    }

    private func finishConversation(generation: UInt64) {
        guard generation == conversationGeneration else { return }
        conversationTask = nil
        guard isRunning, let pending = pendingConversationInput else {
            pendingConversationInput = nil
            return
        }
        pendingConversationInput = nil
        startConversation(pending)
    }

    private func runTranscription(utterance: AudioUtterance, privacy: PrivacyMuteState.Snapshot) async {
        guard privacyMute.permitsSpeech(privacy) else { return }
        let conversation = configuration.pipeline.conversation
        do {
            let (client, configuredLanguage) = try transcriptionSetup()
            let language = configuredLanguage == "auto" ? nil : configuredLanguage
            let transcript = try await client.transcribe(.init(
                wavData: utterance.wavData,
                language: language
            ))
            try Task.checkCancellation()
            guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let displayedTranscript = await translated(transcript)
            try Task.checkCancellation()
            guard isRunning, !realtimeTranscriptionActive, privacyMute.permitsSpeech(privacy) else { return }
            await scene.applyTranscript(displayedTranscript, privacyGeneration: privacy.generation)
            await publish()
            if !Task.isCancelled, privacyMute.permitsSpeech(privacy),
               conversation.enabled, !conversation.realtimeEnabled, let command = agentCommand(
                for: transcript,
                endedAtUptime: utterance.endedAtUptime,
                conversation: conversation
            ) {
                enqueueConversation(.text(command))
            }
        } catch is CancellationError {
            return
        } catch {
            onError("transcription: \(error.localizedDescription)")
        }
    }

    private func transcriptionSetup() throws -> (any TranscriptionClient, String?) {
        let conversation = configuration.pipeline.conversation
        if conversation.transcriptionProvider == .whisper {
            guard let builtinTranscriptionClient else {
                throw NSError(domain: "AICamera.Transcription", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Download the selected Whisper model in Settings to use local transcription."
                ])
            }
            return (builtinTranscriptionClient, conversation.transcriptionLanguage)
        }
        guard let endpointID = conversation.transcriptionEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else {
            throw NSError(domain: "AICamera.Transcription", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Configure OpenAI transcription in Settings."
            ])
        }
        return (try factory.transcription(for: endpoint), endpoint.options["language"]?.stringValue)
    }

    private func translated(_ transcript: TranscriptEvent) async -> TranscriptEvent {
        let translation = configuration.pipeline.translation
        guard translation.enabled, transcript.mode == .final, let builtinTranslationClient else {
            return transcript
        }
        do {
            let text = try await builtinTranslationClient.translate(.init(
                text: transcript.text,
                sourceLanguage: translation.sourceLanguage,
                targetLanguage: translation.targetLanguage
            ))
            return TranscriptEvent(
                text: text,
                mode: transcript.mode,
                startSeconds: transcript.startSeconds,
                endSeconds: transcript.endSeconds
            )
        } catch is CancellationError {
            return transcript
        } catch {
            onError("translation: \(error.localizedDescription)")
            return transcript
        }
    }

    private func agentCommand(
        for transcript: TranscriptEvent,
        endedAtUptime: TimeInterval,
        conversation: ConversationConfiguration
    ) -> String? {
        guard conversation.respondToFinalTranscripts, transcript.mode == .final else { return nil }
        switch conversation.activationMode {
        case .alwaysListening:
            return transcript.text
        case .wakePhrase:
            switch wakePhraseGate.process(
                transcript: transcript.text,
                wakePhrase: conversation.wakePhrase,
                windowSeconds: conversation.wakeWindowSeconds,
                uptime: endedAtUptime
            ) {
            case .ignored, .armed:
                return nil
            case let .command(command):
                return command
            }
        }
    }

    private func runAgent(userText: String, privacy: PrivacyMuteState.Snapshot) async {
        guard privacyMute.permitsSpeech(privacy) else { return }
        let conversation = configuration.pipeline.conversation
        guard let endpointID = conversation.agentEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        do {
            let current = await scene.current()
            let client = try factory.agent(for: endpoint)
            let response = try await client.respond(to: .init(
                systemPrompt: conversation.systemPrompt,
                userText: userText,
                sceneContext: conversation.includeSceneSummary ? current.promptDescription : nil
            ))
            try Task.checkCancellation()
            guard privacyMute.permitsSpeech(privacy) else { return }
            await scene.applyAgentResponse(response, privacyGeneration: privacy.generation)
            await publish()
            await synthesize(response, privacy: privacy)
        } catch is CancellationError {
            return
        } catch {
            onError("agent: \(error.localizedDescription)")
        }
    }

    private func synthesize(_ text: String, privacy: PrivacyMuteState.Snapshot) async {
        guard privacyMute.permitsSpeech(privacy), !Task.isCancelled else { return }
        let conversation = configuration.pipeline.conversation
        guard let endpointID = conversation.speechEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        var streamingPlaybackBegan = false
        var streamingSpeechID: UUID?
        do {
            let client = try factory.speech(for: endpoint)
            let stream = try await client.synthesizeStream(.init(
                text: text,
                voice: conversation.speechVoice,
                instructions: conversation.speechInstructions,
                responseFormat: "wav"
            ))
            let speechID = UUID()
            streamingSpeechID = speechID
            // Create the iterator before any playback await so cancellation during admission also
            // terminates the network producer instead of abandoning an unconsumed stream.
            var chunkIterator = stream.chunks.makeAsyncIterator()
            switch stream.format.encoding {
            case .wav:
                var wavData = Data()
                while let chunk = try await chunkIterator.next() {
                    try Task.checkCancellation()
                    guard chunk.count <= URLSessionHTTPTransport.defaultMaximumResponseBytes - wavData.count else {
                        throw HTTPAdapterError.responseTooLarge(URLSessionHTTPTransport.defaultMaximumResponseBytes)
                    }
                    wavData.append(chunk)
                }
                try Task.checkCancellation()
                guard !wavData.isEmpty else {
                    throw HTTPAdapterError.invalidResponse("empty speech response")
                }
                guard await emitSpeech(.wav(speechID: speechID, data: wavData), privacy: privacy) else {
                    throw CancellationError()
                }
            case .pcm16LittleEndian:
                guard let sampleRate = stream.format.sampleRate,
                      let channels = stream.format.channelCount else {
                    throw HTTPAdapterError.invalidResponse("missing streaming PCM format")
                }
                guard await emitSpeech(
                    .beginPCM(speechID: speechID, sampleRate: sampleRate, channels: channels), privacy: privacy
                ) else {
                    throw CancellationError()
                }
                streamingPlaybackBegan = true
                try Task.checkCancellation()
                let maximumIngressBytes = sampleRate * MemoryLayout<Int16>.size
                while let chunk = try await chunkIterator.next() {
                    try Task.checkCancellation()
                    var offset = chunk.startIndex
                    while offset < chunk.endIndex {
                        let byteCount = min(
                            maximumIngressBytes,
                            chunk.distance(from: offset, to: chunk.endIndex)
                        )
                        let end = chunk.index(offset, offsetBy: byteCount)
                        let boundedChunk = Data(chunk[offset..<end])
                        guard await emitSpeech(.pcm(speechID: speechID, data: boundedChunk), privacy: privacy) else {
                            throw CancellationError()
                        }
                        offset = end
                    }
                }
                try Task.checkCancellation()
                guard await emitSpeech(.finishPCM(speechID: speechID), privacy: privacy) else {
                    throw CancellationError()
                }
                streamingPlaybackBegan = false
            }
        } catch is CancellationError {
            if streamingPlaybackBegan {
                _ = await stopSpeech(streamingSpeechID)
            }
            return
        } catch {
            if streamingPlaybackBegan {
                _ = await stopSpeech(streamingSpeechID)
            }
            onError("speech: \(error.localizedDescription)")
        }
    }

    private func isFresh(_ packet: FrameAnalysisPacket, for stage: VideoStageConfiguration) -> Bool {
        isRunning && Date().timeIntervalSince(packet.capturedAt) * 1_000 <= Double(stage.maximumFrameAgeMilliseconds)
    }

    private func expireOverlayResults() async {
        let cutoff = Date().addingTimeInterval(-configuration.overlays.resultTTLSeconds)
        if await scene.expireResults(olderThan: cutoff) {
            await publish()
        }
    }

    private func stopSpeech(_ id: UUID?) async -> Bool {
        if let onSpeechWithPrivacy { return await onSpeechWithPrivacy(.stop(speechID: id), privacyMute.snapshot) }
        return await onSpeech(.stop(speechID: id))
    }

    private func emitSpeech(_ event: SpeechPlaybackEvent, privacy: PrivacyMuteState.Snapshot) async -> Bool {
        guard privacyMute.permitsSpeech(privacy), !Task.isCancelled else { return false }
        if let onSpeechWithPrivacy { return await onSpeechWithPrivacy(event, privacy) }
        return await onSpeech(event)
    }

    private func publish() async {
        let privacy = privacyMute.snapshot
        let snapshot = await scene.current(privacyGeneration: privacy.generation)
        guard isRunning, privacyMute.isCurrent(privacy) else { return }
        let visible = privacyMute.filtered(snapshot, from: privacy)
        if let onSnapshotWithPrivacy { onSnapshotWithPrivacy(visible, privacy) }
        else { onSnapshot(visible) }
    }

    func resetGestureControls() { gestureControls = GestureControlGate() }

    /// Called for both edges so unmute also discards work admitted before the privacy boundary.
    func synchronizePrivacy(_ privacy: PrivacyMuteState.Snapshot) async {
        guard privacyMute.isCurrent(privacy) else { return }
        cancelRealtimeCaptions()
        transcriptionGeneration &+= 1
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pendingUtterance = nil
        conversationGeneration &+= 1
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
        wakePhraseGate.reset()
        await scene.clearSpeech()
        await publish()
    }
}
