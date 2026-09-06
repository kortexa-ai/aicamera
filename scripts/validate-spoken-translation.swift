import AICameraCore
import AVFoundation
import Foundation

private struct Failure: Error, CustomStringConvertible { let description: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(description: message) }
}
private struct NoSecrets: SecretResolver {
    func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String? {
        throw Failure(description: "Unexpected credential request")
    }
}
private struct Transcript: TranscriptionClient {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptEvent { .init(text: "Good morning.") }
}
private struct Translator: TranslationClient {
    func translate(_ request: TranslationRequest) async throws -> String { "Buenos días." }
}
private struct SyntheticVoice: TranslationVoiceClient {
    func synthesize(text: String, language: String) async throws -> PCM16Audio {
        let samples = (0..<11_025).map { Int16(6_000 * sin(Double($0) * 2 * .pi * 997 / 22_050)).littleEndian }
        return PCM16Audio(samples: samples.withUnsafeBytes { Data($0) }, sampleRate: 22_050, channels: 1)
    }
}
private actor ControlledVoice: TranslationVoiceClient {
    var calls = 0
    private var pending: CheckedContinuation<PCM16Audio, Error>?
    func synthesize(text: String, language: String) async throws -> PCM16Audio {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func finish() { pending?.resume(returning: PCM16Audio(samples: Data(repeating: 0, count: 8_000), sampleRate: 16_000, channels: 1)); pending = nil }
}
private final class Results: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [SpokenTranslationSegment] = []
    private var events = 0
    private var captions = 0
    private var errors = 0
    func segment(_ value: SpokenTranslationSegment) { lock.lock(); defer { lock.unlock() }; segments.append(value) }
    func event() { lock.lock(); defer { lock.unlock() }; events += 1 }
    func caption(_ value: SceneSnapshot) { lock.lock(); defer { lock.unlock() }; if value.transcript != nil { captions += 1 } }
    func error() { lock.lock(); defer { lock.unlock() }; errors += 1 }
    var values: ([SpokenTranslationSegment], Int, Int, Int) { lock.lock(); defer { lock.unlock() }; return (segments, events, captions, errors) }
}

@main
struct Validation {
    @MainActor static func main() async throws {
        try coreMix()
        try await outputOwnership()
        try await completePlayback()
        try await boundedQueue()
        try await coordinator()
        if CommandLine.arguments.contains("--system-voice") {
            for (language, text) in [("en", "The little sun is smiling."), ("es", "El pequeño sol está sonriendo.")] {
                let audio = try await LocalTranslationVoice().synthesize(text: text, language: language)
                try require(audio.sampleRate > 0 && audio.samples.count > 100, "Empty installed-voice output")
                print("Installed \(language) voice: \(audio.sampleRate) Hz, \(audio.samples.count / 2) frames; no playback or files")
            }
        }
        print("Spoken translation passed: offline mix, output ownership, stale/cancelled work, bounded queue, independent captions and Realtime input.")
    }

    private static func makeSegment(_ state: SpokenTranslationState, _ privacy: PrivacyMuteState) -> SpokenTranslationSegment {
        let outcome = TranslationOutcome.success(.init(text: "Good morning."), text: "Buenos días.", source: .microphone,
            sourceLanguage: state.snapshot.sourceLanguage, targetLanguage: state.snapshot.targetLanguage)!
        return SpokenTranslationSegment(id: UUID(), outcome: outcome, capturedAt: ProcessInfo.processInfo.systemUptime,
                                        voice: state.snapshot, privacy: privacy.snapshot)!
    }

    private static func coreMix() throws {
        for rate in [44_100.0, 48_000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
            let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate))!
            input.frameLength = input.frameCapacity
            for c in 0..<2 { for i in 0..<Int(input.frameLength) { input.floatChannelData![c][i] = 0.8 * sin(Float(i) * 2 * .pi * 997 / Float(rate)) } }
            var duck = TranslationDucking()
            let reduced = duck.outgoing(input, speaking: true)!
            try require(abs(duck.gain - 0.25) < 0.001, "Duck target")
            let i = Int(rate / 2)
            try require(abs(reduced.floatChannelData![0][i] - input.floatChannelData![0][i] * 0.25) < 0.0001, "Ducking changed clean input")
            _ = duck.outgoing(input, speaking: false)
            try require(duck.gain == 1, "Original microphone did not recover")
            let engine = AVAudioEngine(), mic = AVAudioPlayerNode(), speech = AVAudioPlayerNode()
            engine.attach(mic); engine.attach(speech)
            engine.connect(mic, to: engine.mainMixerNode, format: format)
            engine.connect(speech, to: engine.mainMixerNode, format: format)
            let limiter = TranslationAudioMix.installLimiter(in: engine, format: format)
            _ = limiter
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
            try engine.start()
            mic.volume = 8; speech.volume = 8
            mic.scheduleBuffer(input); speech.scheduleBuffer(input); mic.play(); speech.play()
            let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024)!
            var peak: Float = 0
            for _ in 0..<Int(rate / 1_024) {
                try require(try engine.renderOffline(1_024, to: output) == .success, "Offline limiter render")
                for c in 0..<2 { for i in 0..<Int(output.frameLength) {
                    let sample = output.floatChannelData![c][i]
                    try require(sample.isFinite, "Non-finite mix")
                    peak = max(peak, abs(sample))
                } }
            }
            engine.stop()
            try require(peak > 0.1 && peak <= 1.01, "Mix clipped at \(rate): \(peak)")
            print("Offline mix \(Int(rate)) Hz, both gains 8: peak \(peak)")
        }
    }

    @MainActor private static func outputOwnership() async throws {
        let state = SpokenTranslationState(), privacy = PrivacyMuteState()
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        let segment = makeSegment(state, privacy)
        let audio = AudioPipelineController(configuration: AICameraConfiguration.default.capture, privacyMute: privacy,
            utteranceSeconds: 3, transcriptionEnabled: false, spokenTranslation: state,
            onUtterance: { _ in }, onBargeIn: {}, onError: { _ in })
        try audio.startOfflineForValidation()
        defer { audio.stop() }
        func send(_ event: SpeechPlaybackEvent, _ origin: SpokenTranslationSegment? = nil) async -> Bool {
            await withCheckedContinuation { completion in audio.handleSpeech(event, translation: origin) { completion.resume(returning: $0) } }
        }
        try require(await send(.beginPCM(speechID: segment.id, sampleRate: 22_050, channels: 1), segment), "Voice did not acquire output")
        try require(await send(.stop(speechID: nil)), "Agent stop acknowledgement")
        try require(audio.speechIDForValidation == segment.id, "Agent stop interrupted translation")
        let agent = UUID()
        try require(await send(.beginPCM(speechID: agent, sampleRate: 24_000, channels: 1)), "Agent did not preempt translation")
        try require(!(await send(.pcm(speechID: segment.id, data: Data(repeating: 0, count: 100)), segment)), "Late translator interrupted agent")
        try require(!(await send(.stop(speechID: segment.id), segment)), "Old translator stopped agent")
        try require(audio.speechIDForValidation == agent, "Agent output lost ownership")
        _ = await send(.stop(speechID: agent))
        state.set(enabled: false, targetLanguage: "es", agentBusy: false)
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        try require(!(await send(.beginPCM(speechID: segment.id, sampleRate: 22_050, channels: 1), segment)), "Off/On revived old speech")
        let fresh = makeSegment(state, privacy)
        try require(await send(.beginPCM(speechID: fresh.id, sampleRate: 22_050, channels: 1), fresh), "Fresh voice rejected")
        privacy.setMuted(true)
        audio.silenceForPrivacy()
        privacy.setMuted(false)
        try require(!(await send(.beginPCM(speechID: fresh.id, sampleRate: 22_050, channels: 1), fresh)), "Unmute revived old speech")
        try require(audio.speechIDForValidation == nil, "Muted output retained speech")
    }

    private static func boundedQueue() async throws {
        let state = SpokenTranslationState(), privacy = PrivacyMuteState(), voice = ControlledVoice(), results = Results()
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        let controller = SpokenTranslationController(state: state, privacy: privacy, client: voice,
            output: { event, _ in if case .stop = event {} else { results.event() }; return true },
            onError: { _, _ in results.error() })
        let first = makeSegment(state, privacy)
        await controller.submit(first)
        for _ in 0..<100 { if await voice.calls == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        await controller.submit(first) // same utterance must not enter twice
        await controller.submit(makeSegment(state, privacy))
        await controller.submit(makeSegment(state, privacy))
        try require(results.values.3 == 1, "Queue overflow was not surfaced")
        state.set(enabled: false, targetLanguage: "es", agentBusy: false)
        await controller.invalidate(); await voice.finish()
        try await Task.sleep(for: .milliseconds(30))
        try require(results.values.1 == 0, "Cancellation-insensitive voice leaked audio")
        try require(await voice.calls == 1, "ASR/voice queue grew beyond the active request")
    }

    @MainActor private static func completePlayback() async throws {
        let state = SpokenTranslationState(), privacy = PrivacyMuteState(), results = Results()
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        var configuration = AICameraConfiguration.default.capture
        configuration.audioSampleRate = 48_000
        let audio = AudioPipelineController(configuration: configuration, privacyMute: privacy,
            utteranceSeconds: 3, transcriptionEnabled: false, spokenTranslation: state,
            onUtterance: { _ in }, onBargeIn: {}, onError: { _ in results.error() })
        try audio.startOfflineForValidation()
        defer { audio.stop() }
        let controller = SpokenTranslationController(state: state, privacy: privacy, client: SyntheticVoice(),
            output: { event, segment in
                let accepted = await withCheckedContinuation { continuation in
                    audio.handleSpeech(event, translation: segment) { continuation.resume(returning: $0) }
                }
                if case .finishPCM = event, accepted { results.event() }
                return accepted
            }, onError: { _, _ in results.error() })
        await controller.submit(makeSegment(state, privacy))
        var output: [Float] = []
        for _ in 0..<500 {
            let buffer = try audio.renderOfflineForValidation(frames: 1_024)
            output.append(contentsOf: UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
            if results.values.1 == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        let audible = output.indices.filter { abs(output[$0]) > 0.005 }
        try require(!audible.isEmpty && results.values.1 == 1 && results.values.3 == 0, "Voice did not drain through the production player: audible=\(audible.count), finished=\(results.values.1), errors=\(results.values.3), owner=\(audio.speechIDForValidation != nil)")
        let duration = Double(audible.last! - audible.first! + 1) / 48_000
        try require(abs(duration - 0.5) < 0.01, "Voice changed duration: \(duration)")
        let crossings = (audible.first! + 1...audible.last!).filter { output[$0 - 1] < 0 && output[$0] >= 0 }.count
        try require(abs(Double(crossings) / duration - 997) < 8, "Voice changed pitch")
        try require(audio.speechIDForValidation == nil, "Completed translation retained output ownership")
        print("Complete production voice playback: 22050 → 48000 Hz, \(duration)s, \(crossings) tone cycles; offline only")
    }

    private static func coordinator() async throws {
        let state = SpokenTranslationState(), privacy = PrivacyMuteState(), results = Results()
        let features = RuntimeFeatureState(transcription: false, translation: false)
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        var configuration = AICameraConfiguration.default
        configuration.pipeline.conversation.enabled = false
        configuration.pipeline.conversation.transcriptionEnabled = true
        configuration.pipeline.conversation.transcriptionProvider = .whisper
        configuration.pipeline.translation.enabled = true
        configuration.pipeline.translation.targetLanguage = "es"
        let coordinator = PipelineCoordinator(configuration: configuration, secrets: NoSecrets(), privacyMute: privacy,
            runtimeFeatures: features, spokenTranslation: state, onSpokenTranslation: { results.segment($0) },
            onSpokenTranslationError: { _, _ in results.error() }, builtinTranslationClient: Translator(),
            builtinTranscriptionClient: Transcript(), onSnapshot: { results.caption($0) }, onError: { _ in results.error() })
        await coordinator.setRealtimeTranscriptionActive(true)
        await coordinator.submit(utterance: AudioUtterance(wavData: Data(), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        for _ in 0..<100 { if results.values.0.count == 1 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try require(results.values.0.count == 1 && results.values.0[0].text == "Buenos días.", "Realtime input suppressed local voice translation")
        try require(results.values.2 == 0 && results.values.3 == 0, "Voice enabled hidden captions or failed")
        state.set(enabled: true, targetLanguage: "es", agentBusy: true)
        await coordinator.submit(utterance: AudioUtterance(wavData: Data(), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        try await Task.sleep(for: .milliseconds(30))
        try require(results.values.0.count == 1, "Microphone translated during agent answer")
        await coordinator.setRealtimeTranscriptionActive(false)
        state.set(enabled: true, targetLanguage: "es", agentBusy: false)
        await coordinator.submit(utterance: AudioUtterance(wavData: Data(), endedAtUptime: ProcessInfo.processInfo.systemUptime))
        for _ in 0..<100 { if results.values.0.count == 2 { break }; try await Task.sleep(for: .milliseconds(5)) }
        try require(results.values.0.count == 2, "Agent input pause stopped independent translation")
        await coordinator.stop()
    }
}
