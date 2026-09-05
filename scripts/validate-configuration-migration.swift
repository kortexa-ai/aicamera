import AICameraCore
import Foundation

/// Runs the real settings controller against disposable synthetic files. No app launch, media,
/// network, or credential resolver is linked into this executable.
@main
struct ConfigurationMigrationValidation {
    struct Failure: Error { let message: String }

    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure(message: message) }
    }

    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aicamera-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settingsURL = directory.appendingPathComponent("settings.json")
        let store = ConfigurationStore(fileURL: settingsURL)
        var legacy = AICameraConfiguration.default
        ConfigurationController.installOpenAITranscriptionConfiguration(in: &legacy)
        legacy.endpoints[0].baseURL = URL(string: "https://legacy.example")!
        legacy.privacy.allowedHosts = ["legacy.example"]
        legacy.pipeline.translation.enabled = true
        legacy.overlays.showTranscript = true
        var expected = legacy
        expected.pipeline.conversation.transcriptionEnabled = false

        try store.save(legacy)
        let controller = ConfigurationController(fileURL: settingsURL)
        try require(controller.isConfigurationUsable, "migration blocked a valid file")
        try require(controller.configuration == expected, "startup changed more than the unsupported route")
        try require(try store.load() == expected, "startup did not persist disabled transcription")
        let migratedBytes = try Data(contentsOf: settingsURL)
        controller.reload()
        try require(controller.profileTransferMessage == nil, "migration was not idempotent")
        try require(try Data(contentsOf: settingsURL) == migratedBytes, "reload rewrote migrated settings")

        try store.save(legacy)
        controller.reload()
        try require(controller.configuration == expected, "reload did not normalize unsupported transcription")
        let importURL = directory.appendingPathComponent("import.json")
        try ProfileTransfer.write(legacy, to: importURL)
        controller.importProfile(from: importURL)
        try require(controller.configuration == expected, "import did not normalize unsupported transcription")
        try require(try store.load() == expected, "import did not persist disabled transcription")

        var openAI = expected
        ConfigurationController.installOpenAITranscriptionConfiguration(in: &openAI)
        try store.save(openAI)
        controller.reload()
        try require(controller.configuration == openAI, "explicit OpenAI setup was changed")
        try require(controller.profileTransferMessage == nil, "supported OpenAI was marked unsupported")
        var whisper = expected
        ConfigurationController.installWhisperTranscriptionConfiguration(in: &whisper, model: .base, language: "auto")
        try store.save(whisper)
        let relaunched = ConfigurationController(fileURL: settingsURL)
        try require(relaunched.configuration == whisper, "local Whisper changed on relaunch")
        try require(relaunched.configuration.pipeline.conversation.transcriptionEndpointID == nil, "Whisper retained an active remote endpoint")

        let invalidBytes = Data("not valid settings".utf8)
        try invalidBytes.write(to: settingsURL)
        controller.reload()
        try require(!controller.isConfigurationUsable, "invalid settings did not block capture")
        try require(try Data(contentsOf: settingsURL) == invalidBytes, "invalid settings were overwritten")
        print("PASS: startup/reload/import migration, persistence, idempotence, explicit OpenAI setup, local Whisper relaunch, invalid-file preservation; no credential or media access")
    }
}
