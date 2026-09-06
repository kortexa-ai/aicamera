import AICameraCore
import Foundation

// Native coordinator acceptance with controlled completions and actual local translation.
// Synthetic text only; no camera, microphone, network, Keychain, or captured-media files.
private struct HarnessFailure: Error { let message: String }
private func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw HarnessFailure(message: message) }
}
private struct NoSecrets: SecretResolver {
    func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String? {
        throw HarnessFailure(message: "Unexpected credential resolution")
    }
}
private final class Captions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    private var errors: [String] = []
    private var agentValues: [String] = []
    func record(_ snapshot: SceneSnapshot) {
        lock.lock(); defer { lock.unlock() }
        if let text = snapshot.agentResponse {
            agentValues.append(text)
            if agentValues.count > 256 { agentValues.removeFirst() }
        }
        if let text = snapshot.transcript?.text {
            values.append(text)
            if values.count > 256 { values.removeFirst() }
        }
    }
    func recordError(_ text: String) {
        lock.lock(); defer { lock.unlock() }
        errors.append(String(text.prefix(256)))
    }
    var texts: [String] { lock.lock(); defer { lock.unlock() }; return values }
    var agentTexts: [String] { lock.lock(); defer { lock.unlock() }; return agentValues }
    var hasErrors: Bool { lock.lock(); defer { lock.unlock() }; return !errors.isEmpty }
}
private actor ControlledTranslation: TranslationClient {
    private var inputs: [String] = []
    private var requests: [TranslationRequest] = []
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    func translate(_ request: TranslationRequest) async throws -> String {
        inputs.append(request.text)
        requests.append(request)
        // Deliberately ignore cancellation: the coordinator must reject late completions itself.
        return try await withCheckedThrowingContinuation { pending[request.text] = $0 }
    }
    var started: [String] { inputs }
    var languages: [String] { requests.map { $0.sourceLanguage + "→" + $0.targetLanguage } }
    func finish(_ text: String, output: String? = nil) {
        pending.removeValue(forKey: text)?.resume(returning: output ?? "translated-" + text)
    }
    func fail(_ text: String) {
        pending.removeValue(forKey: text)?.resume(throwing: HarnessFailure(message: "Synthetic translation failure"))
    }
}

@main private struct RealtimeCaptionValidation {
    @MainActor static func main() async throws {
        try await controlledChecks()
        try await talkCompletionChecks()
        try await speakerChecks()
        try await languageChangeChecks()
        try await translationFailureChecks()
        if CommandLine.arguments.contains("--controlled-only") { return }
        let controller = BuiltinTranslationModelController()
        guard let client = controller.makeTranslationClient() else {
            throw HarnessFailure(message: "Download HY-MT2 in the app before the real-model check")
        }
        let captions = Captions()
        let coordinator = makeCoordinator(client: client, captions: captions)
        await coordinator.setRealtimeTranscriptionActive(true)
        let text = "The camera is ready. Hello, world!"
        let start = ProcessInfo.processInfo.systemUptime
        await coordinator.submitRealtimeTranscript(source: .local, text: text, isFinal: true)
        let admitted = ProcessInfo.processInfo.systemUptime - start
        try require(admitted < 0.2, "Caption admission waited for local inference")
        try await waitUntil(seconds: 30) {
            captions.texts.last.map { $0 != text && $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } } ?? false
        }
        let output = captions.texts.last ?? ""
        try require(!output.contains("\u{FFFD}") && !captions.hasErrors, "Invalid translated caption")
        let userFinalSeconds = ProcessInfo.processInfo.systemUptime - start
        await coordinator.submitRealtimeTranscript(source: .remote, text: "The assistant is ready.", isFinal: true)
        try await waitUntil(seconds: 10) {
            captions.agentTexts.last.map { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } } ?? false
        }
        try require(captions.texts.last == output && !captions.hasErrors
            && !(captions.agentTexts.last ?? "").contains("\u{FFFD}"), "Invalid AI translation or replaced user caption")
        print("Native HY-MT2 captions: admission=\(admitted)s userFinal=\(userFinalSeconds)s bothFinal=\(ProcessInfo.processInfo.systemUptime - start)s text=\(output)")
        await coordinator.stop()
        print("Passed real local-model caption publication without media or network")
    }

    private static func makeCoordinator(client: any TranslationClient, captions: Captions,
                                        showTranscript: Bool = true, showAgentResponse: Bool = true,
                                        features: RuntimeFeatureState = RuntimeFeatureState()) -> PipelineCoordinator {
        var profile = AICameraConfiguration.default
        profile.overlays.enabled = true
        profile.overlays.showTranscript = showTranscript
        profile.overlays.showAgentResponse = showAgentResponse
        profile.pipeline.translation.enabled = true
        profile.pipeline.translation.sourceLanguage = "en"
        profile.pipeline.translation.targetLanguage = "zh"
        return PipelineCoordinator(configuration: profile, secrets: NoSecrets(), runtimeFeatures: features, builtinTranslationClient: client,
            onSnapshot: { captions.record($0) }, onSpeech: { _ in true }, onError: { captions.recordError($0) })
    }

    private static func translationFailureChecks() async throws {
        for output in [nil, "", " \n", "invalid\0text", String(repeating: "a", count: 8_193)] as [String?] {
            let client = ControlledTranslation(), captions = Captions()
            let coordinator = makeCoordinator(client: client, captions: captions)
            await coordinator.setRealtimeTranscriptionActive(true)
            await coordinator.submitRealtimeTranscript(source: .local, text: "original-on-failure", isFinal: true)
            try await waitUntil { await client.started == ["original-on-failure"] }
            if let output { await client.finish("original-on-failure", output: output) }
            else { await client.fail("original-on-failure") }
            try await waitUntil { captions.hasErrors }
            try require(captions.texts.last == "original-on-failure", "Translation failure lost original caption")
            await coordinator.submitRealtimeTranscript(source: .local, text: "recovered", isFinal: true)
            try await waitUntil { await client.started == ["original-on-failure", "recovered"] }
            await client.finish("recovered")
            try await waitUntil { captions.texts.last == "translated-recovered" }
            if let output { try require(!captions.texts.contains(output), "Invalid translation reached captions") }
            await coordinator.stop()
        }
        print("Passed translation outcomes: failure/empty/invalid/oversized output preserves originals, reports errors, and recovers")
    }

    private static func languageChangeChecks() async throws {
        let client = ControlledTranslation(), captions = Captions(), features = RuntimeFeatureState()
        features.set(transcription: true, translation: true, gestures: true,
                     translationSourceLanguage: "en", translationTargetLanguage: "zh")
        let coordinator = makeCoordinator(client: client, captions: captions, features: features)
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submitRealtimeTranscript(source: .local, text: "old-language", isFinal: true)
        try await waitUntil { await client.started == ["old-language"] }
        features.set(transcription: true, translation: true, gestures: true,
                     translationSourceLanguage: "en", translationTargetLanguage: "es")
        await coordinator.synchronizeRuntimeFeatures()
        await coordinator.submitRealtimeTranscript(source: .local, text: "new-language", isFinal: true)
        try require(await client.started == ["old-language"], "Language change overlapped translation workers")
        await client.finish("old-language")
        try await waitUntil { await client.started == ["old-language", "new-language"] }
        try require(await client.languages == ["en→zh", "en→es"], "New caption used stale target language")
        try require(!captions.texts.contains("translated-old-language"), "Old language completion republished a caption")
        await client.finish("new-language")
        try await waitUntil { captions.texts.last == "translated-new-language" }

        features.set(transcription: true, translation: false, gestures: true,
                     translationSourceLanguage: "en", translationTargetLanguage: "es")
        await coordinator.synchronizeRuntimeFeatures()
        await coordinator.submitRealtimeTranscript(source: .local, text: "translation-off", isFinal: true)
        try require(captions.texts.last == "translation-off", "Translation Off lost original captions")
        try require(await client.started == ["old-language", "new-language"], "Disabled translation performed inference")
        try require(!captions.hasErrors, "Language changes caused a coordinator error")
        await coordinator.stop()
        print("Passed live language controls: new target, stale-result rejection, one translation worker, Off preserves original captions")
    }

    private static func controlledChecks() async throws {
        let client = ControlledTranslation(), captions = Captions()
        let coordinator = makeCoordinator(client: client, captions: captions)
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submitRealtimeTranscript(source: .local, text: "partial", isFinal: false)
        try require(await client.started.isEmpty, "Partial transcript started translation")
        try require(captions.texts.last == "partial", "Partial caption not published")
        await coordinator.submitRealtimeTranscript(source: .local, text: "first", isFinal: true)
        try await waitUntil { await client.started == ["first"] }
        let started = ProcessInfo.processInfo.systemUptime
        await coordinator.submitRealtimeTranscript(source: .local, text: "second", isFinal: true)
        await coordinator.submitRealtimeTranscript(source: .local, text: "third", isFinal: true)
        try require(ProcessInfo.processInfo.systemUptime - started < 0.2, "Busy translation blocked event admission")
        try require(await client.started == ["first"], "More than one active translation")
        await client.finish("first")
        try await waitUntil { await client.started == ["first", "third"] }
        try require(!captions.texts.contains("translated-first"), "Superseded completion replaced a newer caption")
        await client.finish("third")
        try await waitUntil { captions.texts.last == "translated-third" }
        await coordinator.submitRealtimeTranscript(source: .local, text: "retired-turn", isFinal: true)
        try await waitUntil { await client.started.contains("retired-turn") }
        await coordinator.setRealtimeTranscriptionActive(true)
        await client.finish("retired-turn")
        try await Task.sleep(for: .milliseconds(50))
        try require(!captions.texts.contains("translated-retired-turn"), "Previous turn published into a new turn")
        await coordinator.submitRealtimeTranscript(source: .local, text: "stopped", isFinal: true)
        try await waitUntil { await client.started.contains("stopped") }
        await coordinator.stop()
        let before = captions.texts
        await client.finish("stopped")
        await coordinator.submitRealtimeTranscript(source: .local, text: "after-stop", isFinal: true)
        try await Task.sleep(for: .milliseconds(50))
        try require(captions.texts == before && !captions.hasErrors, "Late work published after Stop")
        print("Passed controlled captions: partial/final, nonblocking admission, one active/latest pending, supersession, new-turn isolation, Stop")
    }

    private static func speakerChecks() async throws {
        for showUser in [false, true] {
            for showAgent in [false, true] {
                let captions = Captions(), client = ControlledTranslation()
                let coordinator = makeCoordinator(client: client, captions: captions,
                    showTranscript: showUser, showAgentResponse: showAgent)
                await coordinator.submitRealtimeTranscript(source: .local, text: "user", isFinal: false)
                await coordinator.submitRealtimeTranscript(source: .remote, text: "assistant", isFinal: false)
                try require(captions.texts.isEmpty == !showUser, "User caption ignored its display switch")
                try require(captions.agentTexts.isEmpty == !showAgent, "AI caption ignored its independent switch")
                await coordinator.stop()
            }
        }
        let captions = Captions(), client = ControlledTranslation()
        let coordinator = makeCoordinator(client: client, captions: captions)
        await coordinator.submitRealtimeTranscript(source: .local, text: "user-final", isFinal: true)
        try await waitUntil { await client.started == ["user-final"] }
        await coordinator.submitRealtimeTranscript(source: .remote, text: "assistant-partial", isFinal: false)
        await client.finish("user-final")
        try await waitUntil { captions.texts.last == "translated-user-final" }
        try require(captions.agentTexts.last == "assistant-partial", "User translation replaced AI caption")
        await coordinator.submitRealtimeTranscript(source: .remote, text: "assistant-final", isFinal: true)
        try await waitUntil { await client.started.contains("assistant-final") }
        await client.finish("assistant-final")
        try await waitUntil { captions.agentTexts.last == "translated-assistant-final" }
        try require(captions.texts.last == "translated-user-final", "AI translation replaced user caption")
        await coordinator.stop()
        print("Passed speaker routes: all display-switch combinations, interleaved sources, independent translated finals")
    }

    private static func talkCompletionChecks() async throws {
        let captions = Captions(), client = ControlledTranslation()
        let coordinator = makeCoordinator(client: client, captions: captions)
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submitRealtimeTranscript(source: .local, text: "stop-active", isFinal: true)
        try await waitUntil { await client.started == ["stop-active"] }
        await coordinator.submitRealtimeTranscript(source: .remote, text: "stop-pending", isFinal: true)
        // Match Talk Stop cleanup without stopping the still-active camera coordinator.
        await coordinator.cancelRealtimeCaptions()
        await coordinator.setRealtimeTranscriptionActive(false)
        let beforeUser = captions.texts, beforeAgent = captions.agentTexts
        await client.finish("stop-active")
        try await Task.sleep(for: .milliseconds(50))
        try require(captions.texts == beforeUser && captions.agentTexts == beforeAgent,
                    "Talk Stop allowed a late translation to publish")
        try require(await client.started == ["stop-active"], "Talk Stop started pending translation")

        // A successful response may finish playing before its final caption is translated.
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submitRealtimeTranscript(source: .remote, text: "normal-final", isFinal: true)
        try await waitUntil { await client.started.contains("normal-final") }
        await coordinator.setRealtimeTranscriptionActive(false)
        await client.finish("normal-final")
        try await waitUntil { captions.agentTexts.last == "translated-normal-final" }

        // Cancellation of the event consumer must prevent a queued event from creating work.
        let canceledEvent = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await coordinator.submitRealtimeTranscript(source: .local, text: "canceled-event", isFinal: true)
        }
        await canceledEvent.value
        try require(!captions.texts.contains("canceled-event"), "Canceled event consumer published a caption")
        try require(!(await client.started).contains("canceled-event"), "Canceled event started translation")
        try require(!captions.hasErrors, "Talk completion checks reported a pipeline error")
        await coordinator.stop()
        print("Passed Talk completion: cancel active/pending captions with camera still active, preserve normal final translation, reject canceled events, retry")
    }

    private static func waitUntil(seconds: Double = 3, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HarnessFailure(message: "Caption fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
