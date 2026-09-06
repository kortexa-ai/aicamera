import AVFoundation
import Foundation

// Explicit feasibility probe: fixed synthetic text -> in-memory PCM metrics only.
// No speak(), player, capture device, personal voice, credential, or saved audio is used.
@main
struct LocalSpeechValidation {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 1 else { throw Failure("This probe takes no user text or audio.") }
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { !$0.voiceTraits.contains(.isPersonalVoice) }
        for (language, text) in [("en-US", "This is a synthetic translation test."),
                                 ("es-ES", "Esta es una prueba de traducción.")] {
            guard let voice = voices.filter({ $0.language == language })
                .min(by: { $0.quality.rawValue < $1.quality.rawValue }) else {
                throw Failure("No available system voice for \(language). Install a voice manually before this optional probe.")
            }
            let synthesizer = AVSpeechSynthesizer()
            defer { synthesizer.stopSpeaking(at: .immediate) }
            let utterance = AVSpeechUtterance(string: text)
            utterance.voice = voice
            let collector = Metrics()
            synthesizer.write(utterance) { buffer in collector.accept(buffer) }
            let deadline = ProcessInfo.processInfo.systemUptime + 15
            while !collector.finished, ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            // Stop only this private synthesis job. No output engine has been created.
            synthesizer.stopSpeaking(at: .immediate)
            print("\(language): \(try collector.result()). No playback or audio file.")
        }
        print("Local system-voice buffer synthesis passed for two fixed synthetic utterances. This does not test translation quality or call routing.")
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    final class Metrics: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        private var error: String?
        private var frames = 0
        private var callbacks = 0
        private var sampleRate: Double?
        private var channels: AVAudioChannelCount?
        private var peak: Float = 0

        var finished: Bool { lock.lock(); defer { lock.unlock() }; return done }

        func accept(_ value: AVAudioBuffer) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            guard let buffer = value as? AVAudioPCMBuffer else { fail("Non-PCM synthesis output"); return }
            guard buffer.frameLength > 0 else { done = true; return }
            let rate = buffer.format.sampleRate
            let count = buffer.format.channelCount
            guard rate.isFinite, (8_000...96_000).contains(rate), (1...2).contains(count),
                  !buffer.format.isInterleaved, buffer.format.commonFormat == .pcmFormatFloat32,
                  let data = buffer.floatChannelData,
                  sampleRate == nil || sampleRate == rate,
                  channels == nil || channels == count else { fail("Unsupported or changing PCM format"); return }
            let length = Int(buffer.frameLength)
            guard length <= Int(rate * 15), frames <= Int(rate * 15) - length,
                  callbacks < 256 else { fail("Synthetic utterance exceeded bounded output"); return }
            sampleRate = rate; channels = count; frames += length; callbacks += 1
            for channel in 0..<Int(count) {
                for index in 0..<length {
                    let sample = data[channel][index]
                    guard sample.isFinite, abs(sample) <= 1 else { fail("Invalid PCM sample"); return }
                    peak = max(peak, abs(sample))
                }
            }
        }

        private func fail(_ message: String) { error = message; done = true }

        func result() throws -> String {
            lock.lock(); defer { lock.unlock() }
            if let error { throw Failure(error) }
            guard done, let sampleRate, let channels, frames > 0, peak > 0.001 else {
                throw Failure("Synthesis timed out or produced no audible PCM samples")
            }
            return "\(frames) frames, \(Int(sampleRate)) Hz, \(channels) channel(s), \(callbacks) bounded buffers"
        }
    }
}
