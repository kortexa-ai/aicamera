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
    func finishTranslation(_ key: String) { translations.removeValue(forKey: key)?.resume(returning: "translated-" + key) }
    func finishTranscription(_ key: String) { transcriptions.removeValue(forKey: key)?.resume(returning: .init(text: key)) }
}
@main
private struct CaptionPrivacyValidation {
    static func main() async throws {
        try await translationChecks()
        try await transcriptionChecks()
        try await gestureChecks()
        print("Passed caption privacy: immediate clear, muted admission, delayed completions across both edges, fresh recovery, gesture routing")
    }
    private static func coordinator(_ gate: PrivacyMuteState, _ results: Results, _ models: Models,
                                    translation: Bool) -> PipelineCoordinator {
        var config = AICameraConfiguration.default
        config.pipeline.conversation.enabled = false
        config.pipeline.conversation.transcriptionEnabled = true
        config.pipeline.conversation.transcriptionProvider = .whisper
        config.pipeline.translation.enabled = translation
        config.pipeline.translation.targetLanguage = "zh"
        config.overlays.showTranscript = true
        config.overlays.showAgentResponse = true
        return PipelineCoordinator(configuration: config, secrets: NoSecrets(), privacyMute: gate,
            onGestureControl: { if $0 == .mute { gate.setMuted(true) } },
            builtinTranslationClient: models, builtinTranscriptionClient: models,
            onSnapshotWithPrivacy: { results.record($0, $1) }, onError: { results.error($0) })
    }
    private static func translationChecks() async throws {
        let gate = PrivacyMuteState(), results = Results(), models = Models()
        let pipeline = coordinator(gate, results, models, translation: true)
        await pipeline.started()
        await pipeline.submitRealtimeTranscript(source: .local, text: "old", isFinal: true)
        try await wait { await models.translated == ["old"] }
        await pipeline.submitRealtimeTranscript(source: .remote, text: "old-pending", isFinal: true)
        await pipeline.synchronizePrivacy(gate.setMuted(true))
        try require(results.latest.transcript == nil && results.latest.agentResponse == nil, "Mute did not clear both speakers")
        await pipeline.submitRealtimeTranscript(source: .local, text: "muted", isFinal: true)
        try require(!results.values.contains("muted"), "Muted event published")
        await pipeline.synchronizePrivacy(gate.setMuted(false))
        await pipeline.submitRealtimeTranscript(source: .remote, text: "fresh", isFinal: true)
        await models.finishTranslation("old")
        try await wait { await models.translated == ["old", "fresh"] }
        await models.finishTranslation("fresh")
        try await wait { results.latest.agentResponse == "translated-fresh" }
        try require(!results.values.contains("translated-old"), "Retired translation resurfaced after unmute")
        try require(results.latest.transcript == nil && !results.hasErrors, "Speech leaked or coordinator failed")
        await pipeline.stop()
    }
    private static func transcriptionChecks() async throws {
        let gate = PrivacyMuteState(), results = Results(), models = Models()
        let pipeline = coordinator(gate, results, models, translation: false)
        await pipeline.submit(utterance: .init(wavData: Data("old".utf8), endedAtUptime: 1))
        try await wait { await models.transcribed == ["old"] }
        await pipeline.synchronizePrivacy(gate.setMuted(true))
        await pipeline.submit(utterance: .init(wavData: Data("muted".utf8), endedAtUptime: 2))
        await pipeline.synchronizePrivacy(gate.setMuted(false))
        await models.finishTranscription("old")
        await pipeline.submit(utterance: .init(wavData: Data("fresh".utf8), endedAtUptime: 3))
        try await wait { await models.transcribed == ["old", "fresh"] }
        await models.finishTranscription("fresh")
        try await wait { results.latest.transcript?.text == "fresh" }
        try require(!results.values.contains("old") && !results.hasErrors, "Retired transcription published")
        await pipeline.stop()
    }
    private static func gestureChecks() async throws {
        let gate = PrivacyMuteState(), results = Results(), models = Models()
        let pipeline = coordinator(gate, results, models, translation: false)
        await pipeline.submitRealtimeTranscript(source: .local, text: "visible", isFinal: false)
        for index in 0...10 {
            let time = ProcessInfo.processInfo.systemUptime
            await pipeline.submit(gestures: [.init(kind: .closedFist, confidence: 0.95)],
                frameID: .init(rawValue: UInt64(index + 1)), capturedAt: time)
            try await Task.sleep(for: .milliseconds(100))
        }
        try require(gate.snapshot.isMuted, "Held fist did not reach privacy callback")
        try require(results.latest.transcript == nil && !results.latest.gestures.isEmpty,
                    "Gesture mute did not hide speech while preserving camera observations")
        await pipeline.stop()
    }
    private static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "Fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
