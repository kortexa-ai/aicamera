// See docs/testing.md for the C bridge and framework compile commands.
// Uses only the pinned public upstream JFK fixture; never captures media or reads Keychain.
import AICameraCore
import CryptoKit
import Darwin
import Foundation

private enum ValidationError: Error { case failed(String) }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw ValidationError.failed(message) }
}

@main private struct LocalWhisperValidation {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count >= 2 else { throw ValidationError.failed("Supply the pinned JFK WAV fixture path") }
        let model = CommandLine.arguments.count > 2 ? BuiltinWhisperModel(rawValue: CommandLine.arguments[2]) : .base
        guard let model else { throw ValidationError.failed("Unknown model") }
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: CommandLine.arguments[1]))
        defer { try? file.close() }
        let wav = try file.read(upToCount: 1_000_000) ?? Data()
        let hash = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
        try require(hash == "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e", "Use the pinned upstream public fixture")
        let controller = BuiltinWhisperModelController()
        guard let client = controller.makeTranscriptionClient(model: model) as? BuiltinWhisperClient else {
            throw ValidationError.failed("Download the selected Whisper model in Settings first")
        }
        try require(controller.makeTranscriptionClient(model: model) as? BuiltinWhisperClient === client, "Model client was not cached")
        let silent = WAVFile.encodePCM16(samples: Data(count: 32_000), sampleRate: 16_000, channels: 1)
        let silence = try await client.transcribe(.init(wavData: silent))
        try require(silence.text.isEmpty, "Silence produced a transcript")
        for language in [String?.some("en"), nil] {
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await client.transcribe(.init(wavData: wav, language: language))
            let normalized = result.text.lowercased()
            try require(normalized.contains("ask not") && normalized.contains("country"), "Fixture speech was not recognized")
            print("model=\(model.rawValue) language=\(language ?? "auto") audioSeconds=\(try WhisperInput(wavData: wav).duration) inferenceSeconds=\(ProcessInfo.processInfo.systemUptime - start) characters=\(result.text.count)")
        }
        let pcm = try WAVFile.decodePCM16(wav)
        let repeated = WAVFile.encodePCM16(samples: pcm.samples + pcm.samples, sampleRate: 16_000, channels: 1)
        let operation = Task { try await client.transcribe(.init(wavData: repeated, language: "en")) }
        try await Task.sleep(for: .milliseconds(20))
        let cancelStart = ProcessInfo.processInfo.systemUptime
        operation.cancel()
        do {
            _ = try await operation.value
            throw ValidationError.failed("Cancelled inference completed normally")
        } catch is CancellationError {
            print("cancellationSeconds=\(ProcessInfo.processInfo.systemUptime - cancelStart)")
        }
        let recovered = try await client.transcribe(.init(wavData: wav, language: "en"))
        try require(recovered.text.lowercased().contains("country"), "Whisper did not recover after cancellation")
        let translationController = BuiltinTranslationModelController()
        guard let translator = translationController.makeTranslationClient() else {
            throw ValidationError.failed("Download HY-MT2 for the combined native-engine check")
        }
        let translated = try await translator.translate(.init(text: "The camera is ready.", sourceLanguage: "en", targetLanguage: "zh"))
        try require(!translated.isEmpty && !translated.contains("\u{FFFD}"), "Combined translation failed")
        let coexistence = try await client.transcribe(.init(wavData: wav, language: "en"))
        try require(coexistence.text.lowercased().contains("country"), "Whisper failed with the translation engine loaded")
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        print("Whisper fixture, silence, cancellation, recovery, cache, and combined-engine checks passed; peakResidentBytes=\(usage.ru_maxrss)")
    }
}
