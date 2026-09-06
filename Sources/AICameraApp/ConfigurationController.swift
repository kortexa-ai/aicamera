import AICameraCore
import Foundation

@MainActor
final class ConfigurationController: ObservableObject {
    // Preserve the original Keychain account name while sharing one OpenAI API key
    // across Realtime and transcription.
    static let openAICredentialAccount = "openai-realtime"
    static let realtimeCredentialAccount = openAICredentialAccount
    static let openAIAPIBaseURL = URL(string: "https://api.openai.com")!
    static let openAIRealtimeBaseURL = openAIAPIBaseURL
    static let openAITranscriptionEndpointID = "openai-transcription"
    nonisolated static let defaultTranscriptionModel = "gpt-transcribe"
    static let transcriptionModels = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let defaultRealtimeModel = "gpt-realtime-2"
    static let defaultRealtimeVoice = "marin"
    static let realtimeModels = ["gpt-realtime-2", "gpt-realtime-1.5", "gpt-realtime"]
    static let realtimeVoices = ["marin", "cedar", "coral", "alloy", "ash", "ballad", "echo", "sage", "shimmer", "verse"]

    static func realtimeCredentialAccount(for baseURL: URL) -> String {
        guard let host = baseURL.host?.lowercased(), host != "api.openai.com" else {
            return realtimeCredentialAccount
        }
        return "realtime-\(host)"
    }

    @Published private(set) var configuration: AICameraConfiguration
    @Published private(set) var validationMessage: String?
    @Published private(set) var profileTransferMessage: String?
    @Published private(set) var isConfigurationUsable = true

    let fileURL: URL
    private let store: ConfigurationStore

    init(fileURL: URL = ConfigurationController.defaultFileURL()) {
        self.fileURL = fileURL
        self.store = ConfigurationStore(fileURL: fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                self.configuration = try store.load()
            } catch {
                // Preserve invalid or newer-schema profiles instead of silently replacing them.
                self.configuration = .default
                self.validationMessage = "The saved profile was not changed: \(error.localizedDescription)"
                self.isConfigurationUsable = false
            }
        } else {
            self.configuration = .default
            do {
                try store.save(.default)
            } catch {
                self.validationMessage = "The default profile could not be saved: \(error.localizedDescription)"
            }
        }
        migrateUnsupportedConfiguration()
    }

    static func installOpenAITranscriptionConfiguration(
        in profile: inout AICameraConfiguration,
        model: String = defaultTranscriptionModel,
        language: String = "auto"
    ) {
        let endpointID = openAITranscriptionEndpointID
        let endpoint = EndpointConfiguration(
            id: endpointID,
            adapter: .openAITranscription,
            baseURL: openAIAPIBaseURL,
            model: model,
            auth: .init(kind: .bearerKeychain, reference: openAICredentialAccount),
            timeoutSeconds: 30,
            options: ["language": .string(language)]
        )
        profile.endpoints.removeAll(where: { $0.id == endpointID })
        profile.endpoints.append(endpoint)
        profile.pipeline.conversation.transcriptionEnabled = true
        profile.pipeline.conversation.transcriptionProvider = .openAI
        profile.pipeline.conversation.transcriptionEndpointID = endpointID
        profile.pipeline.conversation.transcriptionLanguage = language
        profile.privacy.networkMode = .allowListed
        if !profile.privacy.allowedHosts.map({ $0.lowercased() }).contains("api.openai.com") {
            profile.privacy.allowedHosts.append("api.openai.com")
        }
        profile.privacy.grants.removeAll(where: { $0.endpointID == endpointID })
        profile.privacy.grants.append(.init(endpointID: endpointID, allowedData: [.rawAudio]))
    }

    static func installWhisperTranscriptionConfiguration(
        in profile: inout AICameraConfiguration, model: BuiltinWhisperModel, language: String
    ) {
        profile.pipeline.conversation.transcriptionProvider = .whisper
        profile.pipeline.conversation.transcriptionWhisperModel = model
        profile.pipeline.conversation.transcriptionLanguage = language
        profile.pipeline.conversation.transcriptionEndpointID = nil
        profile.pipeline.conversation.transcriptionEnabled = true
    }

    private func migrateUnsupportedConfiguration() {
        guard isConfigurationUsable else { return }
        var candidate = configuration
        guard let migrationMessage = normalizeSupportedConfiguration(in: &candidate) else { return }
        do {
            try ConfigurationValidator.validate(candidate)
            try store.save(candidate)
            configuration = candidate
            profileTransferMessage = migrationMessage
        } catch {
            isConfigurationUsable = false
            validationMessage = "The legacy configuration could not be migrated: \(error.localizedDescription)"
        }
    }

    private func normalizeSupportedConfiguration(
        in candidate: inout AICameraConfiguration
    ) -> String? {
        guard SupportedConfigurationPolicy.disableUnsupportedRoutes(in: &candidate) else { return nil }
        return "Disabled unsupported services. Select OpenAI or a local model in AI to enable those features."
    }

    func update(_ change: (inout AICameraConfiguration) -> Void) {
        guard isConfigurationUsable else {
            validationMessage = "Repair and save the profile in AI before changing other settings."
            return
        }
        var candidate = configuration
        change(&candidate)
        do {
            try ConfigurationValidator.validate(candidate)
            try store.save(candidate)
            configuration = candidate
            isConfigurationUsable = true
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    func importProfile(from url: URL) {
        do {
            var candidate = try ProfileTransfer.read(from: url)
            let migrationMessage = normalizeSupportedConfiguration(in: &candidate)
            try store.save(candidate)
            configuration = candidate
            isConfigurationUsable = true
            validationMessage = nil
            profileTransferMessage = migrationMessage ?? "Imported \(candidate.profileName)."
        } catch {
            profileTransferMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    func exportProfile(to url: URL) {
        do {
            try ProfileTransfer.write(configuration, to: url)
            profileTransferMessage = "Exported profile without secret values."
        } catch {
            profileTransferMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    func reload() {
        do {
            var candidate = try store.load()
            let migrationMessage = normalizeSupportedConfiguration(in: &candidate)
            if migrationMessage != nil { try store.save(candidate) }
            configuration = candidate
            isConfigurationUsable = true
            validationMessage = nil
            profileTransferMessage = migrationMessage
        } catch {
            isConfigurationUsable = false
            validationMessage = error.localizedDescription
        }
    }

    func resetToDefaults() {
        do {
            try store.save(.default)
            configuration = .default
            isConfigurationUsable = true
            validationMessage = nil
            profileTransferMessage = "Reset to the pure-passthrough defaults."
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI Camera", isDirectory: true).appendingPathComponent("profile.json")
    }

}
