import AICameraCore
import Foundation

/// One active segment and one pending segment. Playback acknowledgements include the audible tail.
actor SpokenTranslationController {
    typealias Output = @Sendable (SpeechPlaybackEvent, SpokenTranslationSegment) async -> Bool
    private let state: SpokenTranslationState
    private let privacy: PrivacyMuteState
    private let client: any TranslationVoiceClient
    private let output: Output
    private let onError: @Sendable (String, SpokenTranslationState.Snapshot) -> Void
    private var task: Task<Void, Never>?
    private var active: SpokenTranslationSegment?
    private var pending: SpokenTranslationSegment?
    private var recentIDs: [UUID] = []

    init(state: SpokenTranslationState, privacy: PrivacyMuteState, client: any TranslationVoiceClient,
         output: @escaping Output, onError: @escaping @Sendable (String, SpokenTranslationState.Snapshot) -> Void) {
        self.state = state; self.privacy = privacy; self.client = client; self.output = output; self.onError = onError
    }

    func submit(_ segment: SpokenTranslationSegment) {
        guard permitted(segment) else { reportExpired(segment); return }
        guard !recentIDs.contains(segment.id) else { return }
        recentIDs.append(segment.id)
        if recentIDs.count > 16 { recentIDs.removeFirst() }
        if task != nil {
            guard pending == nil else {
                pending = nil; task?.cancel()
                onError("Voice could not keep up. It is off; your original microphone continues.", segment.voice)
                return
            }
            pending = segment
        } else { start(segment) }
    }

    func invalidate() {
        // A delayed MainActor notification must not cancel fresh work from a newer generation.
        if let pending, !permitted(pending) { self.pending = nil }
        if let active, !permitted(active) { task?.cancel() }
    }

    private func permitted(_ segment: SpokenTranslationSegment) -> Bool {
        state.permits(segment.voice, capturedAt: segment.capturedAt) && privacy.permitsSpeech(segment.privacy)
    }

    private func start(_ segment: SpokenTranslationSegment) {
        active = segment
        task = Task { [weak self] in
            guard let self else { return }
            await self.speak(segment)
            await self.finished()
        }
    }

    private func finished() {
        task = nil; active = nil
        let next = pending; pending = nil
        if let next {
            if permitted(next) { start(next) } else { reportExpired(next) }
        }
    }

    private func speak(_ segment: SpokenTranslationSegment) async {
        do {
            guard permitted(segment), !Task.isCancelled else { return }
            let audio = try await client.synthesize(text: segment.text, language: segment.voice.targetLanguage)
            try Task.checkCancellation()
            guard permitted(segment) else { reportExpired(segment); return }
            guard audio.channels == 1, (8_000...96_000).contains(audio.sampleRate),
                  !audio.samples.isEmpty, audio.samples.count.isMultiple(of: 2),
                  audio.samples.count <= audio.sampleRate * 2 * 12 else {
                throw AudioPipelineError(message: "The translation voice returned invalid or excessive audio.")
            }
            guard await output(.beginPCM(speechID: segment.id, sampleRate: audio.sampleRate, channels: 1), segment) else {
                reportPlaybackFailure(segment); return
            }
            let chunkBytes = max(2, audio.sampleRate / 4 * 2)
            for offset in stride(from: 0, to: audio.samples.count, by: chunkBytes) {
                try Task.checkCancellation()
                guard permitted(segment), await output(.pcm(speechID: segment.id,
                    data: audio.samples.subdata(in: offset..<min(audio.samples.count, offset + chunkBytes))), segment) else {
                    _ = await output(.stop(speechID: segment.id), segment)
                    reportPlaybackFailure(segment)
                    return
                }
            }
            guard !Task.isCancelled, permitted(segment) else { throw CancellationError() }
            if !(await output(.finishPCM(speechID: segment.id), segment)) { reportPlaybackFailure(segment) }
        } catch {
            _ = await output(.stop(speechID: segment.id), segment)
            if !(error is CancellationError), permitted(segment) { onError(error.localizedDescription, segment.voice) }
        }
    }

    private func reportPlaybackFailure(_ segment: SpokenTranslationSegment) {
        reportExpired(segment)
        guard !Task.isCancelled, permitted(segment) else { return }
        onError("Voice output stopped. Voice is off; your original microphone continues.", segment.voice)
    }

    private func reportExpired(_ segment: SpokenTranslationSegment) {
        guard !Task.isCancelled, state.isCurrent(segment.voice), privacy.permitsSpeech(segment.privacy),
              ProcessInfo.processInfo.systemUptime - segment.capturedAt > 20 else { return }
        onError("Voice fell behind. Voice is off; your original microphone continues.", segment.voice)
    }
}
