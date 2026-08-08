import AICameraCore
import Foundation

struct FrameAnalysisPacket: Sendable {
    let frameID: FrameID
    let capturedAt: Date
    let jpegData: Data
    let width: Int
    let height: Int
}

actor PipelineCoordinator {
    private enum ConversationInput: Sendable {
        case utterance(Data)
        case text(String)
    }

    typealias SnapshotHandler = @Sendable (SceneSnapshot) -> Void
    typealias SpeechHandler = @Sendable (Data) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void

    private let configuration: AICameraConfiguration
    private let scene = SceneState()
    private let factory: AdapterFactory
    private let onSnapshot: SnapshotHandler
    private let onSpeech: SpeechHandler
    private let onError: ErrorHandler

    private var runningStages = Set<String>()
    private var stageTasks: [String: Task<Void, Never>] = [:]
    private var pendingPackets: [String: FrameAnalysisPacket] = [:]
    private var isRunning = true
    private var lastStageStart: [String: Date] = [:]
    private var conversationTask: Task<Void, Never>?
    private var pendingConversationInput: ConversationInput?
    private var conversationGeneration: UInt64 = 0
    private var lastGestureResponse = Date.distantPast
    private var lastObservedGestureKind: GestureKind?
    private var expiryTask: Task<Void, Never>?

    init(
        configuration: AICameraConfiguration,
        secrets: any SecretResolver,
        onSnapshot: @escaping SnapshotHandler,
        onSpeech: @escaping SpeechHandler,
        onError: @escaping ErrorHandler
    ) {
        self.configuration = configuration
        self.factory = AdapterFactory(
            secrets: secrets,
            privacy: PrivacyGate(configuration: configuration.privacy)
        )
        self.onSnapshot = onSnapshot
        self.onSpeech = onSpeech
        self.onError = onError
    }

    func started() async {
        guard isRunning else { return }
        await scene.setStatus("AI Camera proxy live · \(configuration.privacy.networkMode.rawValue)")
        await publish()
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
                await self?.expireOverlayResults()
            }
        }
    }

    func stop() {
        isRunning = false
        conversationGeneration &+= 1
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
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

    func submit(gestures: [GestureObservation], frameID: FrameID) async {
        guard isRunning else { return }
        _ = await scene.applyGestures(gestures, frameID: frameID)
        await publish()

        let conversation = configuration.pipeline.conversation
        guard let gesture = gestures.first(where: { $0.kind != .unknown && $0.confidence >= 0.4 }) else {
            lastObservedGestureKind = nil
            return
        }
        let isNewGesture = gesture.kind != lastObservedGestureKind
        lastObservedGestureKind = gesture.kind
        guard conversation.enabled,
              conversation.respondToGestures,
              isNewGesture,
              Date().timeIntervalSince(lastGestureResponse) >= conversation.gestureCooldownSeconds else { return }
        lastGestureResponse = Date()
        let description = gesture.kind.rawValue
        enqueueConversation(.text("The user made a \(description) gesture. Acknowledge it briefly and respond appropriately."))
    }

    func submit(utteranceWAV: Data) {
        guard isRunning, configuration.pipeline.conversation.enabled else { return }
        enqueueConversation(.utterance(utteranceWAV))
    }

    func askAgentAboutScene() {
        guard isRunning else { return }
        enqueueConversation(.text("Briefly describe what is currently notable and useful in the scene."))
    }

    func bargeIn() async {
        guard configuration.pipeline.conversation.bargeIn else { return }
        conversationGeneration &+= 1
        conversationTask?.cancel()
        conversationTask = nil
        pendingConversationInput = nil
        await scene.applyAgentResponse(nil)
        await publish()
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
        guard let endpointID = stage.endpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        do {
            switch stage.kind {
            case .objectDetection:
                let confidence = stage.options["confidence"]?.numberValue ?? endpoint.options["confidence"]?.numberValue ?? 0.25
                let client = try factory.detection(for: endpoint)
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

    private func enqueueConversation(_ input: ConversationInput) {
        guard isRunning, configuration.pipeline.conversation.enabled else { return }
        if conversationTask != nil {
            if configuration.pipeline.conversation.bargeIn {
                conversationGeneration &+= 1
                conversationTask?.cancel()
                conversationTask = nil
            } else {
                // Preserve at most the latest pending turn while the current turn completes.
                pendingConversationInput = input
                return
            }
        }
        startConversation(input)
    }

    private func startConversation(_ input: ConversationInput) {
        guard isRunning else { return }
        conversationGeneration &+= 1
        let generation = conversationGeneration
        conversationTask = Task { [weak self] in
            guard let self else { return }
            switch input {
            case let .utterance(wavData):
                await self.runConversation(wavData: wavData)
            case let .text(text):
                await self.runAgent(userText: text)
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

    private func runConversation(wavData: Data) async {
        let conversation = configuration.pipeline.conversation
        guard let endpointID = conversation.transcriptionEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        do {
            let client = try factory.transcription(for: endpoint)
            let transcript = try await client.transcribe(.init(wavData: wavData))
            try Task.checkCancellation()
            guard !transcript.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            await scene.applyTranscript(transcript)
            await publish()
            if conversation.respondToFinalTranscripts {
                await runAgent(userText: transcript.text)
            }
        } catch is CancellationError {
            return
        } catch {
            onError("transcription: \(error.localizedDescription)")
        }
    }

    private func runAgent(userText: String) async {
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
            await scene.applyAgentResponse(response)
            await publish()
            await synthesize(response)
        } catch is CancellationError {
            return
        } catch {
            onError("agent: \(error.localizedDescription)")
        }
    }

    private func synthesize(_ text: String) async {
        let conversation = configuration.pipeline.conversation
        guard let endpointID = conversation.speechEndpointID,
              let endpoint = configuration.endpoints.first(where: { $0.id == endpointID }) else { return }
        do {
            let client = try factory.speech(for: endpoint)
            let data = try await client.synthesize(.init(
                text: text,
                voice: conversation.speechVoice,
                instructions: conversation.speechInstructions,
                responseFormat: "wav"
            ))
            try Task.checkCancellation()
            onSpeech(data)
        } catch is CancellationError {
            return
        } catch {
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

    private func publish() async {
        onSnapshot(await scene.current())
    }
}
