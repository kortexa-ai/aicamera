import AICameraCore
import AppKit
import CryptoKit
import Foundation

// The actual NSApplication termination delegate and cached native clients. Public fixture only.
// Keep these owners alive through process exit, as SwiftUI does with the host's AppModel.
@MainActor
private final class Fixture {
    static let retained = Fixture()
    let whisperModels = BuiltinWhisperModelController()
    let translationModels = BuiltinTranslationModelController()
    var whisper: BuiltinWhisperClient?
    var translator: BuiltinTranslationClient?
    var transcription: Task<TranscriptEvent, Error>?
    var translation: Task<String, Error>?
    var shutdownCalls = 0

    func prepare(path: String, duringLoad: Bool) async throws {
        let wav = try Data(contentsOf: URL(fileURLWithPath: path))
        let hash = SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
        try require(hash == "59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e", "Use pinned public JFK fixture")
        guard let whisper = whisperModels.makeTranscriptionClient(model: .base) as? BuiltinWhisperClient,
              let translator = translationModels.makeTranslationClient() as? BuiltinTranslationClient else {
            throw Failure(message: "Download Whisper Base and HY-MT2 first")
        }
        self.whisper = whisper
        self.translator = translator
        if !duringLoad {
            let result = try await whisper.transcribe(.init(wavData: wav, language: "en"))
            try require(result.text.lowercased().contains("country"), "Whisper fixture inference failed")
            let translated = try await translator.translate(.init(text: "The camera is ready.", sourceLanguage: "en", targetLanguage: "zh"))
            try require(!translated.isEmpty, "HY-MT2 fixture inference failed")
        }
        let pcm = try WAVFile.decodePCM16(wav)
        let longer = WAVFile.encodePCM16(samples: pcm.samples + pcm.samples, sampleRate: 16_000, channels: 1)
        transcription = Task { try await whisper.transcribe(.init(wavData: longer, language: "en")) }
        translation = Task { try await translator.translate(.init(text: "The camera is ready. Please explain how to prepare a small garden and grow vegetables during the summer.", sourceLanguage: "en", targetLanguage: "zh")) }
        try await Task.sleep(for: .milliseconds(20))
    }

    func shutdown() async throws {
        shutdownCalls += 1
        try require(shutdownCalls == 1, "Termination cleanup ran more than once")
        transcription?.cancel()
        translation?.cancel()
        await whisperModels.shutdown()
        await translationModels.shutdown()
        _ = await transcription?.result
        _ = await translation?.result
        await whisperModels.shutdown()
        await translationModels.shutdown()
        try require(whisperModels.makeTranscriptionClient(model: .base) == nil, "Whisper cache reopened after shutdown")
        try require(translationModels.makeTranslationClient() == nil, "Translator cache reopened after shutdown")
        let silent = WAVFile.encodePCM16(samples: Data(count: 32_000), sampleRate: 16_000, channels: 1)
        do {
            _ = try await whisper?.transcribe(.init(wavData: silent))
            throw Failure(message: "Retained Whisper client accepted work after shutdown")
        } catch is CancellationError {}
        do {
            _ = try await translator?.translate(.init(text: "Retired", targetLanguage: "zh"))
            throw Failure(message: "Retained translator accepted work after shutdown")
        } catch is CancellationError {}
        print("SHUTDOWN PASSED: native contexts released, cancellation drained, retained clients closed, normal NSApplication termination")
        fflush(stdout)
    }
}
private struct Failure: Error { let message: String }
private func require(_ value: Bool, _ message: String) throws {
    if !value { throw Failure(message: message) }
}
@main
private struct ModelShutdownValidation {
    @MainActor static func main() {
        guard CommandLine.arguments.count >= 2 else { fatalError("Supply public JFK fixture path") }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let delegate = AICameraApplicationDelegate()
        app.delegate = delegate
        let fixture = Fixture.retained
        AppLifecycleCoordinator.shared.prepareForTermination = {
            do { try await fixture.shutdown() }
            catch { fail(error) }
        }
        Task { @MainActor in
            do {
                try await fixture.prepare(path: CommandLine.arguments[1], duringLoad: CommandLine.arguments.contains("--during-load"))
                // Match an AppKit Quit event. Calling terminate synchronously inside a main
                // executor job would keep that job blocked in AppKit's termination modal loop.
                app.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0,
                            inModes: [.default])
            } catch { fail(error) }
        }
        withExtendedLifetime(delegate) { app.run() }
    }
    private static func fail(_ error: Error) -> Never {
        fputs("SHUTDOWN FAILED: \(error)\n", stderr)
        exit(1)
    }
}
