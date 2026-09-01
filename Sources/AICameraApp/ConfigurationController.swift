import AICameraCore
import Foundation

@MainActor
final class ConfigurationController: ObservableObject {
    static let smartyAPIBaseURL = URL(string: "https://api.kortexa.ai")!
    static let smartyCredentialAccount = "kortexa-api"
    // Preserve the original Keychain account name while sharing one OpenAI API key
    // across Realtime and transcription.
    static let openAICredentialAccount = "openai-realtime"
    static let realtimeCredentialAccount = openAICredentialAccount
    static let openAIAPIBaseURL = URL(string: "https://api.openai.com")!
    static let openAIRealtimeBaseURL = openAIAPIBaseURL
    static let openAITranscriptionEndpointID = "openai-transcription"
    static let defaultTranscriptionModel = "gpt-transcribe"
    static let transcriptionModels = ["gpt-transcribe", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
    static let kortexaRealtimeURL = URL(string: "https://api.kortexa.ai/v1/realtime/calls")!
    static let defaultRealtimeModel = "gpt-realtime-2"
    static let defaultRealtimeVoice = "marin"
    static let realtimeModels = ["gpt-realtime-2", "gpt-realtime-1.5", "gpt-realtime"]
    static let realtimeVoices = ["marin", "cedar", "coral", "alloy", "ash", "ballad", "echo", "sage", "shimmer", "verse"]
    static let hermesRealtimeModel = "lfm2.5-8b-a1b"
    static let smartyAgentModels = ["qwen-3.8-27b", "lfm2.5-8b-a1b"]
    static let smartyVisionModel = "lfm2.5-vl-3b"
    static let smartySpeechModel = "qwen3-tts-customvoice-1.7b"
    static let smartyASRModel = "Qwen/Qwen3-ASR-1.7B"
    static let smartyDetectionModel = "yolo26n.pt"

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
    }

    func update(_ change: (inout AICameraConfiguration) -> Void) {
        guard isConfigurationUsable else {
            validationMessage = "Repair and save the profile in AI & Advanced before changing other settings."
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
            let candidate = try ProfileTransfer.read(from: url)
            try store.save(candidate)
            configuration = candidate
            isConfigurationUsable = true
            validationMessage = nil
            profileTransferMessage = "Imported \(candidate.profileName)."
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
            configuration = try store.load()
            isConfigurationUsable = true
            validationMessage = nil
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

    func applySmartyPreset() {
        let local = Self.smartyPreset()
        do {
            try store.save(local)
            configuration = local
            isConfigurationUsable = true
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    func configureSmartyModels(agentModel: String = "qwen-3.8-27b") {
        update { profile in
            Self.installSmartyEndpoints(in: &profile, agentModel: agentModel)
        }
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI Camera", isDirectory: true).appendingPathComponent("profile.json")
    }

    private static func smartyPreset() -> AICameraConfiguration {
        var profile = AICameraConfiguration(
            profileName: "Kortexa Smarty",
            pipeline: .init(
                videoStages: [
                    .init(id: "hands", kind: .handGesture, maximumRateHz: 8, maximumFrameAgeMilliseconds: 250),
                    .init(
                        id: "objects",
                        kind: .objectDetection,
                        endpointID: "smarty-objects",
                        maximumRateHz: 2,
                        maximumFrameAgeMilliseconds: 1_000,
                        options: ["confidence": .number(0.35)]
                    ),
                    .init(
                        id: "vision",
                        kind: .visionLanguage,
                        enabled: false,
                        endpointID: "smarty-vision",
                        maximumRateHz: 0.2,
                        maximumFrameAgeMilliseconds: 2_000,
                        prompt: "Describe only visual facts useful to a conversational camera assistant."
                    ),
                ],
                conversation: .init(
                    enabled: true,
                    transcriptionEnabled: true,
                    transcriptionEndpointID: "smarty-asr",
                    agentEndpointID: "smarty-agent",
                    speechEndpointID: "smarty-speech",
                    speechVoice: "adrian"
                )
            ),
            overlays: .init(enabled: true)
        )
        installSmartyEndpoints(in: &profile, agentModel: smartyAgentModels[0])
        return profile
    }

    private static func installSmartyEndpoints(
        in profile: inout AICameraConfiguration,
        agentModel: String
    ) {
        let selectedAgentModel = smartyAgentModels.contains(agentModel) ? agentModel : smartyAgentModels[0]
        let auth = EndpointAuthConfiguration(
            kind: .apiKeyKeychain,
            reference: smartyCredentialAccount,
            header: "x-api-key",
            prefix: ""
        )
        let endpoints: [EndpointConfiguration] = [
            .init(
                id: "smarty-objects",
                adapter: .kortexaDetection,
                baseURL: smartyAPIBaseURL.appendingPathComponent("vision"),
                model: smartyDetectionModel,
                auth: auth,
                timeoutSeconds: 4,
                options: ["confidence": .number(0.35)]
            ),
            .init(
                id: "smarty-asr",
                adapter: .openAITranscription,
                baseURL: smartyAPIBaseURL,
                model: smartyASRModel,
                auth: auth,
                timeoutSeconds: 20
            ),
            .init(
                id: "smarty-agent",
                adapter: .openAIChat,
                baseURL: smartyAPIBaseURL,
                model: selectedAgentModel,
                auth: auth,
                timeoutSeconds: 30,
                options: ["temperature": .number(0.4), "max_tokens": .number(256)]
            ),
            .init(
                id: "smarty-vision",
                adapter: .openAIVision,
                baseURL: smartyAPIBaseURL,
                model: smartyVisionModel,
                auth: auth,
                timeoutSeconds: 20
            ),
            .init(
                id: "smarty-speech",
                adapter: .openAISpeech,
                baseURL: smartyAPIBaseURL,
                model: smartySpeechModel,
                auth: auth,
                timeoutSeconds: 60,
                options: ["streamingPCM": .bool(true), "pcmSampleRate": .number(24_000)]
            ),
            .init(
                id: "smarty-realtime",
                adapter: .openAIRealtime,
                baseURL: smartyAPIBaseURL,
                model: selectedAgentModel,
                auth: auth,
                timeoutSeconds: 30,
                options: ["voice": .string("adrian")]
            ),
        ]

        let managedIDs = Set(endpoints.map(\.id))
        profile.endpoints.removeAll { managedIDs.contains($0.id) }
        profile.endpoints.append(contentsOf: endpoints)
        for index in profile.pipeline.videoStages.indices {
            switch profile.pipeline.videoStages[index].kind {
            case .objectDetection:
                profile.pipeline.videoStages[index].endpointID = "smarty-objects"
            case .visionLanguage:
                profile.pipeline.videoStages[index].endpointID = "smarty-vision"
            case .handGesture:
                break
            }
        }
        profile.pipeline.conversation.transcriptionEndpointID = "smarty-asr"
        profile.pipeline.conversation.agentEndpointID = "smarty-agent"
        profile.pipeline.conversation.speechEndpointID = "smarty-speech"
        if !profile.pipeline.conversation.realtimeEnabled
            || profile.pipeline.conversation.realtimeEndpointID == nil
            || profile.pipeline.conversation.realtimeEndpointID == "smarty-realtime" {
            profile.pipeline.conversation.realtimeEndpointID = "smarty-realtime"
        }
        profile.privacy.networkMode = .allowListed
        if !profile.privacy.allowedHosts.map({ $0.lowercased() }).contains("api.kortexa.ai") {
            profile.privacy.allowedHosts.append("api.kortexa.ai")
        }
        profile.privacy.grants.removeAll { managedIDs.contains($0.endpointID) }
        profile.privacy.grants.append(contentsOf: [
            .init(endpointID: "smarty-objects", allowedData: [.rawFrame]),
            .init(endpointID: "smarty-asr", allowedData: [.rawAudio]),
            .init(endpointID: "smarty-agent", allowedData: [.promptText, .transcript, .sceneMetadata]),
            .init(endpointID: "smarty-vision", allowedData: [.rawFrame, .promptText]),
            .init(endpointID: "smarty-speech", allowedData: [.promptText]),
            .init(endpointID: "smarty-realtime", allowedData: [.rawAudio, .transcript, .promptText, .sceneMetadata]),
        ])
    }
}
