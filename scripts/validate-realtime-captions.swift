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
    func record(_ snapshot: SceneSnapshot) {
        lock.lock(); defer { lock.unlock() }
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
    var hasErrors: Bool { lock.lock(); defer { lock.unlock() }; return !errors.isEmpty }
}
private actor ControlledTranslation: TranslationClient {
    private var inputs: [String] = []
    private var pending: [String: CheckedContinuation<String, Error>] = [:]
    func translate(_ request: TranslationRequest) async throws -> String {
        inputs.append(request.text)
        // Deliberately ignore cancellation: the coordinator must reject late completions itself.
        return try await withCheckedThrowingContinuation { pending[request.text] = $0 }
    }
    var started: [String] { inputs }
    func finish(_ text: String) { pending.removeValue(forKey: text)?.resume(returning: "translated-" + text) }
}

@main private struct RealtimeCaptionValidation {
    @MainActor static func main() async throws {
        try await controlledChecks()
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
        await coordinator.submitRealtimeTranscript(text: text, isFinal: true)
        let admitted = ProcessInfo.processInfo.systemUptime - start
        try require(admitted < 0.2, "Caption admission waited for local inference")
        try await waitUntil(seconds: 30) {
            captions.texts.last.map { $0 != text && $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } } ?? false
        }
        let output = captions.texts.last ?? ""
        try require(!output.contains("\u{FFFD}") && !captions.hasErrors, "Invalid translated caption")
        print("Native HY-MT2 caption: admission=\(admitted)s final=\(ProcessInfo.processInfo.systemUptime - start)s text=\(output)")
        await coordinator.stop()
        print("Passed real local-model caption publication without media or network")
    }

    private static func makeCoordinator(client: any TranslationClient, captions: Captions) -> PipelineCoordinator {
        var profile = AICameraConfiguration.default
        profile.overlays.enabled = true
        profile.overlays.showTranscript = true
        profile.pipeline.translation.enabled = true
        profile.pipeline.translation.sourceLanguage = "en"
        profile.pipeline.translation.targetLanguage = "zh"
        return PipelineCoordinator(configuration: profile, secrets: NoSecrets(), builtinTranslationClient: client,
            onSnapshot: { captions.record($0) }, onSpeech: { _ in true }, onError: { captions.recordError($0) })
    }

    private static func controlledChecks() async throws {
        let client = ControlledTranslation(), captions = Captions()
        let coordinator = makeCoordinator(client: client, captions: captions)
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submitRealtimeTranscript(text: "partial", isFinal: false)
        try require(await client.started.isEmpty, "Partial transcript started translation")
        try require(captions.texts.last == "partial", "Partial caption not published")
        await coordinator.submitRealtimeTranscript(text: "first", isFinal: true)
        try await waitUntil { await client.started == ["first"] }
        let started = ProcessInfo.processInfo.systemUptime
        await coordinator.submitRealtimeTranscript(text: "second", isFinal: true)
        await coordinator.submitRealtimeTranscript(text: "third", isFinal: true)
        try require(ProcessInfo.processInfo.systemUptime - started < 0.2, "Busy translation blocked event admission")
        try require(await client.started == ["first"], "More than one active translation")
        await client.finish("first")
        try await waitUntil { await client.started == ["first", "third"] }
        try require(!captions.texts.contains("translated-first"), "Superseded completion replaced a newer caption")
        await client.finish("third")
        try await waitUntil { captions.texts.last == "translated-third" }
        await coordinator.submitRealtimeTranscript(text: "retired-turn", isFinal: true)
        try await waitUntil { await client.started.contains("retired-turn") }
        await coordinator.setRealtimeTranscriptionActive(true)
        await client.finish("retired-turn")
        try await Task.sleep(for: .milliseconds(50))
        try require(!captions.texts.contains("translated-retired-turn"), "Previous turn published into a new turn")
        await coordinator.submitRealtimeTranscript(text: "stopped", isFinal: true)
        try await waitUntil { await client.started.contains("stopped") }
        await coordinator.stop()
        let before = captions.texts
        await client.finish("stopped")
        await coordinator.submitRealtimeTranscript(text: "after-stop", isFinal: true)
        try await Task.sleep(for: .milliseconds(50))
        try require(captions.texts == before && !captions.hasErrors, "Late work published after Stop")
        print("Passed controlled captions: partial/final, nonblocking admission, one active/latest pending, supersession, new-turn isolation, Stop")
    }

    private static func waitUntil(seconds: Double = 3, _ condition: () async -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !(await condition()) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw HarnessFailure(message: "Caption fixture timed out") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
