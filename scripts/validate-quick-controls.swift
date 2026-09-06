import AICameraCore
import Foundation

// Real coordinator, synthetic text/PCM, deliberately cancellation-insensitive model completions.
// No capture controller is started; no credentials, network, weights, or system components are used.
private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
private struct NoSecrets: SecretResolver {
    func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String? {
        throw Failure(message: "Unexpected credential access")
    }
}
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var scenes: [(SceneSnapshot, PrivacyMuteState.Snapshot)] = []
    private var errors: [String] = []
    private var controls: [GestureControlAction] = []
    func control(_ action: GestureControlAction) { lock.lock(); controls.append(action); lock.unlock() }
    var actions: [GestureControlAction] { lock.lock(); defer { lock.unlock() }; return controls }
    func record(_ scene: SceneSnapshot, _ privacy: PrivacyMuteState.Snapshot) {
        lock.lock(); defer { lock.unlock() }
        scenes.append((scene, privacy))
    }
    func error(_ message: String) { lock.lock(); errors.append(message); lock.unlock() }
    var latest: SceneSnapshot { lock.lock(); defer { lock.unlock() }; return scenes.last?.0 ?? SceneSnapshot() }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }
        return scenes.flatMap { [$0.0.transcript?.text, $0.0.agentResponse].compactMap { $0 } }
    }
    var hasErrors: Bool { lock.lock(); defer { lock.unlock() }; return !errors.isEmpty }
}
private actor Models: TranscriptionClient, TranslationClient {
    private var translations: [String: CheckedContinuation<String, Error>] = [:]
    private var transcriptions: [String: CheckedContinuation<TranscriptEvent, Error>] = [:]
    private(set) var translated: [String] = []
    private(set) var transcribed: [String] = []
    func translate(_ request: TranslationRequest) async throws -> String {
        translated.append(request.text)
        return try await withCheckedThrowingContinuation { translations[request.text] = $0 }
    }
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptEvent {
        let key = String(decoding: request.wavData, as: UTF8.self)
        transcribed.append(key)
        return try await withCheckedThrowingContinuation { transcriptions[key] = $0 }
    }
    func failTranslation(_ key: String) { translations.removeValue(forKey: key)?.resume(throwing: Failure(message: "Retired translation error")) }
    func finishTranslation(_ key: String) { translations.removeValue(forKey: key)?.resume(returning: "translated-" + key) }
    func finishTranscription(_ key: String) { transcriptions.removeValue(forKey: key)?.resume(returning: .init(text: key)) }
}
@main
private struct QuickControlsValidation {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("Quick controls failed: \(error)\n".utf8))
            exit(1)
        }
    }
    private static func run() async throws {
        let controls = RuntimeFeatureState()
        let privacy = PrivacyMuteState()
        let results = Results(), models = Models()
        var config = AICameraConfiguration.default
        config.pipeline.conversation.enabled = false
        config.pipeline.conversation.transcriptionEnabled = true
        config.pipeline.conversation.transcriptionProvider = .whisper
        config.pipeline.translation.enabled = true
        config.pipeline.translation.targetLanguage = "zh"
        config.overlays.showTranscript = true
        config.overlays.showAgentResponse = true
        let pipeline = PipelineCoordinator(configuration: config, secrets: NoSecrets(), privacyMute: privacy,
            runtimeFeatures: controls,
            onSnapshotWithFeatures: { scene, state, features in
                results.record(controls.filtered(scene, from: features), state)
            },
            onGestureControl: { results.control($0) },
            builtinTranslationClient: models, builtinTranscriptionClient: models,
            onError: { results.error($0) })
        await pipeline.started()

        // A delayed translation and its queued successor must both retire on Off/On.
        await pipeline.submitRealtimeTranscript(source: .local, text: "old", isFinal: true)
        try await wait { await models.translated == ["old"] }
        await pipeline.submitRealtimeTranscript(source: .remote, text: "queued", isFinal: true)
        controls.set(transcription: true, translation: false, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        controls.set(transcription: true, translation: true, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        await models.finishTranslation("old")
        await pipeline.submitRealtimeTranscript(source: .local, text: "fresh", isFinal: true)
        try await wait { await models.translated == ["old", "fresh"] }
        await models.finishTranslation("fresh")
        try await wait { results.latest.transcript?.text == "translated-fresh" }
        try require(!results.values.contains("translated-old"), "Retired translation resurfaced")

        // With translation paused, original captions continue. Neither control rewrites config.
        controls.set(transcription: true, translation: false, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        await pipeline.submitRealtimeTranscript(source: .local, text: "original", isFinal: true)
        try require(results.latest.transcript?.text == "original", "Original captions unavailable")
        try require(config.pipeline.translation.enabled, "Quick control modified saved config")

        // A deliberately uncooperative ASR completion cannot cross the quick-control boundary.
        await pipeline.submit(utterance: .init(wavData: Data("old-asr".utf8), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        try await wait { await models.transcribed == ["old-asr"] }
        controls.set(transcription: false, translation: false, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        await pipeline.submit(utterance: .init(wavData: Data("disabled-asr".utf8), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        await pipeline.submitRealtimeTranscript(source: .local, text: "hidden-local", isFinal: true)
        try require(results.latest.transcript == nil, "Paused captions visible")
        // Agent answers remain independent of original-language caption display.
        await pipeline.submitRealtimeTranscript(source: .remote, text: "agent-answer", isFinal: true)
        try require(results.latest.agentResponse == "agent-answer", "Agent captions stopped with transcription")
        controls.set(transcription: false, translation: true, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        await pipeline.submit(utterance: .init(wavData: Data("translation-dependency".utf8), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        try await Task.sleep(nanoseconds: 100_000_000)
        let beforeRetiredFinishes = await models.transcribed
        try require(beforeRetiredFinishes == ["old-asr"], "Quick toggle overlapped ASR calls")
        await models.finishTranscription("old-asr")
        try await wait { await models.transcribed == ["old-asr", "translation-dependency"] }
        await models.finishTranscription("translation-dependency")
        try await wait { await models.translated.contains("translation-dependency") }
        await models.finishTranslation("translation-dependency")
        try await wait { results.latest.transcript?.text == "translated-translation-dependency" }
        try require(!results.values.contains("old-asr"), "Retired ASR resurfaced")

        await pipeline.submitRealtimeTranscript(source: .local, text: "retired-error", isFinal: true)
        try await wait { await models.translated.contains("retired-error") }
        controls.set(transcription: true, translation: false, gestures: true)
        await pipeline.synchronizeRuntimeFeatures()
        await models.failTranslation("retired-error")
        try await Task.sleep(nanoseconds: 100_000_000)
        try require(!results.hasErrors, "Cancelled provider error reached the UI")

        // Privacy still dominates every quick control, and fresh gestures require a full hold.
        await pipeline.synchronizePrivacy(privacy.setMuted(true))
        await pipeline.submitRealtimeTranscript(source: .remote, text: "muted-agent", isFinal: true)
        try require(results.latest.transcript == nil && results.latest.agentResponse == nil, "Mute lost priority")
        let now = ProcessInfo.processInfo.systemUptime
        controls.set(transcription: false, translation: true, gestures: false, now: now - 2)
        await pipeline.synchronizeRuntimeFeatures()
        for i in 0...10 {
            await pipeline.submit(gestures: [.init(kind: .victory, confidence: 1)],
                frameID: .init(rawValue: UInt64(i)), capturedAt: now - 1 + Double(i) * 0.1)
        }
        try require(results.actions.isEmpty, "Disabled gestures activated the agent")
        controls.set(transcription: false, translation: true, gestures: true, now: now)
        await pipeline.synchronizeRuntimeFeatures()
        await pipeline.submit(gestures: [.init(kind: .victory, confidence: 1)],
            frameID: .init(rawValue: 20), capturedAt: now - 0.1)
        try require(results.latest.gestures.isEmpty, "Old gesture reappeared after enabling")
        try require(!results.hasErrors, "Unexpected pipeline error")
        await pipeline.stop()
        print("Quick controls passed: caption dependencies, independent agent replies, cancellation-insensitive Off/On, disabled gesture admission, and privacy priority")
    }

    private static func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<200 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw Failure(message: "Timed out waiting for synthetic pipeline state")
    }
}
