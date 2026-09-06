import AICameraCore
import AVFoundation
import Foundation

/// Uses installed, non-personal macOS voices. There is no playback, recording, or download here.
@MainActor
final class LocalTranslationVoice: TranslationVoiceClient {
    static func voice(for language: String) -> AVSpeechSynthesisVoice? {
        // Match the existing translator's resolution of "system" exactly.
        let code = language == "system" ? (Locale.current.language.languageCode?.identifier ?? "en") : language
        let desired = code == "zh-Hant" ? "zh-TW" : code == "zh" ? "zh-CN" : code
        let available = AVSpeechSynthesisVoice.speechVoices().filter {
            !$0.voiceTraits.contains(.isPersonalVoice) && !$0.voiceTraits.contains(.isNoveltyVoice)
        }
        let exact = available.filter { $0.language.caseInsensitiveCompare(desired) == .orderedSame }
        let base = desired.split(separator: "-").first.map(String.init) ?? desired
        let matching = exact.isEmpty ? available.filter {
            $0.language.split(separator: "-").first.map(String.init) == base
                && (code != "zh-Hant" || $0.language == "zh-TW")
        } : exact
        if let preferred = AVSpeechSynthesisVoice(language: desired), matching.contains(where: { $0.identifier == preferred.identifier }) {
            return preferred
        }
        return matching.sorted { ($0.quality.rawValue, $0.identifier) < ($1.quality.rawValue, $1.identifier) }.first
    }

    func synthesize(text: String, language: String) async throws -> PCM16Audio {
        guard !text.isEmpty, text.count <= 800, text.utf8.count <= 3_200,
              let voice = Self.voice(for: language) else {
            throw AudioPipelineError(message: "No installed Mac voice is available for this translation language.")
        }
        let synthesizer = AVSpeechSynthesizer()
        let collector = Collector()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        synthesizer.write(utterance) { collector.accept($0) }
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while !collector.finished {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw AudioPipelineError(message: "The Mac translation voice timed out. Voice is off; your original microphone continues.")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        try Task.checkCancellation()
        return try collector.result()
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var error: String?
        private var rate: Int?
        private var pcm = Data()
        private var callbacks = 0
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }
        func accept(_ value: AVAudioBuffer) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            guard let buffer = value as? AVAudioPCMBuffer else { fail("The Mac voice returned non-PCM audio."); return }
            guard buffer.frameLength > 0 else { done = true; return }
            let hz = buffer.format.sampleRate
            guard hz.isFinite, (8_000...96_000).contains(hz), hz.rounded() == hz,
                  buffer.format.channelCount == 1, !buffer.format.isInterleaved,
                  buffer.format.commonFormat == .pcmFormatFloat32, let samples = buffer.floatChannelData?[0],
                  rate == nil || rate == Int(hz), callbacks < 2_048 else {
                fail("The Mac voice returned an unsupported or changing audio format."); return
            }
            let length = Int(buffer.frameLength)
            guard length <= Int(hz * 12), pcm.count / 2 <= Int(hz * 12) - length else {
                fail("The translated segment is too long to speak live."); return
            }
            var values = [Int16](repeating: 0, count: length)
            for i in 0..<length {
                guard samples[i].isFinite, abs(samples[i]) <= 1 else { fail("The Mac voice returned invalid audio."); return }
                values[i] = Int16(samples[i] * Float(Int16.max)).littleEndian
            }
            values.withUnsafeBytes { pcm.append(contentsOf: $0) }
            rate = Int(hz); callbacks += 1
        }
        private func fail(_ message: String) { error = message; done = true; pcm.removeAll() }
        func result() throws -> PCM16Audio {
            lock.lock(); defer { lock.unlock() }
            if let error { throw AudioPipelineError(message: error) }
            guard done, let rate, !pcm.isEmpty else { throw AudioPipelineError(message: "The Mac voice returned no audio.") }
            return PCM16Audio(samples: pcm, sampleRate: rate, channels: 1)
        }
    }
}
