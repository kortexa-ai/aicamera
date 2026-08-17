import AICameraCore
import Foundation

@MainActor
final class ConfigurationController: ObservableObject {
    @Published private(set) var configuration: AICameraConfiguration
    @Published var jsonText: String = ""
    @Published private(set) var validationMessage: String?
    @Published private(set) var isConfigurationUsable = true

    let fileURL: URL
    private let store: ConfigurationStore

    init(fileURL: URL = ConfigurationController.defaultFileURL()) {
        self.fileURL = fileURL
        self.store = ConfigurationStore(fileURL: fileURL)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                self.configuration = try store.load()
                refreshJSON()
            } catch {
                // Preserve invalid or newer-schema profiles. Show their original text so the
                // operator can repair or copy it instead of silently replacing it.
                self.configuration = .default
                self.jsonText = Self.readProfileTextSafely(from: fileURL)
                self.validationMessage = "The saved profile was not changed: \(error.localizedDescription)"
                self.isConfigurationUsable = false
            }
        } else {
            self.configuration = .default
            do {
                try store.save(.default)
                refreshJSON()
            } catch {
                refreshJSON()
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
            refreshJSON()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    func applyJSON() {
        do {
            let candidate = try JSONDecoder().decode(AICameraConfiguration.self, from: Data(jsonText.utf8))
            try ConfigurationValidator.validate(candidate)
            try store.save(candidate)
            configuration = candidate
            isConfigurationUsable = true
            validationMessage = nil
            refreshJSON()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    func reload() {
        do {
            configuration = try store.load()
            isConfigurationUsable = true
            validationMessage = nil
            refreshJSON()
        } catch {
            isConfigurationUsable = false
            validationMessage = error.localizedDescription
        }
    }

    func applyKortexaLocalPreset() {
        let local = Self.kortexaLocalPreset()
        do {
            try store.save(local)
            configuration = local
            isConfigurationUsable = true
            validationMessage = nil
            refreshJSON()
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    private func refreshJSON() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        jsonText = (try? encoder.encode(configuration)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    nonisolated private static func readProfileTextSafely(from url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let limit = ConfigurationStore.maximumProfileBytes
        guard let data = try? handle.read(upToCount: limit + 1), data.count <= limit else {
            return "Profile is too large to display. The original file was preserved."
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("AI Camera", isDirectory: true).appendingPathComponent("profile.json")
    }

    private static func kortexaLocalPreset() -> AICameraConfiguration {
        let endpoints: [EndpointConfiguration] = [
            .init(
                id: "objects",
                adapter: .kortexaDetection,
                baseURL: URL(string: "http://127.0.0.1:4001")!,
                timeoutSeconds: 4,
                options: ["confidence": .number(0.35)]
            ),
            .init(
                id: "asr",
                adapter: .kortexaPCMTranscription,
                baseURL: URL(string: "http://127.0.0.1:4002")!,
                timeoutSeconds: 20
            ),
            .init(
                id: "agent",
                adapter: .openAIChat,
                baseURL: URL(string: "http://127.0.0.1:2030")!,
                model: "mlx-community/Qwen3.5-2B-MLX-4bit",
                timeoutSeconds: 30,
                options: ["temperature": .number(0.4), "max_tokens": .number(256)]
            ),
            .init(
                id: "vision",
                adapter: .openAIVision,
                baseURL: URL(string: "http://127.0.0.1:2052")!,
                path: "/chat/completions",
                model: "LiquidAI/LFM2.5-VL-450M-MLX-8bit",
                timeoutSeconds: 20
            ),
            .init(
                id: "speech",
                adapter: .openAISpeech,
                baseURL: URL(string: "http://127.0.0.1:4003")!,
                model: "qwen3-tts-customvoice-1.7b",
                timeoutSeconds: 60,
                options: ["streamingPCM": .bool(true)]
            ),
        ]
        let stages: [VideoStageConfiguration] = [
            .init(id: "hands", kind: .handGesture, maximumRateHz: 8, maximumFrameAgeMilliseconds: 250),
            .init(
                id: "objects",
                kind: .objectDetection,
                endpointID: "objects",
                maximumRateHz: 2,
                maximumFrameAgeMilliseconds: 1_000,
                options: ["confidence": .number(0.35)]
            ),
            .init(
                id: "vision",
                kind: .visionLanguage,
                enabled: false,
                endpointID: "vision",
                maximumRateHz: 0.2,
                maximumFrameAgeMilliseconds: 2_000,
                prompt: "Describe only visual facts useful to a conversational camera assistant."
            ),
        ]
        return AICameraConfiguration(
            profileName: "Kortexa local",
            endpoints: endpoints,
            pipeline: .init(
                videoStages: stages,
                conversation: .init(
                    enabled: true,
                    transcriptionEndpointID: "asr",
                    agentEndpointID: "agent",
                    speechEndpointID: "speech"
                )
            )
        )
    }
}
