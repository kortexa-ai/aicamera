import Foundation

public enum ConfigurationError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case emptyProfileName
    case profileTooLarge
    case invalidText(String)
    case tooManyComponents(String)
    case invalidCaptureDimensions
    case invalidFrameRate
    case unsupportedVirtualCameraFormat
    case invalidAudioConfiguration
    case duplicateEndpointID(String)
    case duplicateStageID(String)
    case missingEndpoint(stageID: String, endpointID: String)
    case incompatibleEndpoint(stageID: String, adapter: AdapterKind)
    case insecureRemoteEndpoint(String)
    case invalidSecretReference(String)
    case invalidEndpointURL(String)
    case invalidRate(String)
    case invalidTimeout(String)
    case invalidOption(endpointID: String, option: String)
    case invalidOverlayConfiguration
    case privacyGrantReferencesMissingEndpoint(String)
    case duplicatePrivacyGrant(String)
    case mediaPersistenceUnsupported

    public var errorDescription: String? {
        switch self {
        case let .unsupportedSchema(version): return "Unsupported configuration schema version: \(version)."
        case .emptyProfileName: return "The profile name cannot be empty."
        case .profileTooLarge: return "The profile exceeds the 1 MiB safety limit."
        case let .invalidText(field): return "Profile text field '\(field)' is empty or too long."
        case let .tooManyComponents(field): return "Profile has too many \(field)."
        case .invalidCaptureDimensions: return "Capture width and height must be positive."
        case .invalidFrameRate: return "Capture frame rate must be 15, 30, or 60 fps."
        case .unsupportedVirtualCameraFormat: return "Virtual camera size must be 640×480, 1280×720, or 1920×1080."
        case .invalidAudioConfiguration: return "Audio rate, channel count, and gains are invalid."
        case let .duplicateEndpointID(id): return "Endpoint ID '\(id)' is duplicated."
        case let .duplicateStageID(id): return "Video stage ID '\(id)' is duplicated."
        case let .missingEndpoint(stage, endpoint): return "Stage '\(stage)' references missing endpoint '\(endpoint)'."
        case let .incompatibleEndpoint(stage, adapter): return "Stage '\(stage)' cannot use adapter '\(adapter.rawValue)'."
        case let .insecureRemoteEndpoint(id): return "Endpoint '\(id)' must use HTTPS unless it is on the local machine."
        case let .invalidSecretReference(id): return "Endpoint '\(id)' contains an invalid secret reference or credential-like profile value."
        case let .invalidEndpointURL(id): return "Endpoint '\(id)' must use a plain HTTP(S) base URL without user info, query, or fragment."
        case let .invalidRate(id): return "Stage '\(id)' must have a positive maximum rate and frame age."
        case let .invalidTimeout(id): return "Endpoint '\(id)' timeout must be finite and from 0.1 through 600 seconds."
        case let .invalidOption(endpoint, option): return "Endpoint '\(endpoint)' has an invalid numeric option '\(option)'."
        case .invalidOverlayConfiguration: return "Overlay TTL must be finite and from 0.1 through 3600 seconds."
        case let .privacyGrantReferencesMissingEndpoint(id): return "Privacy grant references missing endpoint '\(id)'."
        case let .duplicatePrivacyGrant(id): return "Privacy grant for endpoint '\(id)' is duplicated."
        case .mediaPersistenceUnsupported: return "Raw media persistence is not supported in this version."
        }
    }
}

public enum ConfigurationValidator {
    public static func validate(_ configuration: AICameraConfiguration) throws {
        guard configuration.schemaVersion == AICameraConfiguration.currentSchemaVersion else {
            throw ConfigurationError.unsupportedSchema(configuration.schemaVersion)
        }
        guard !configuration.profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.emptyProfileName
        }
        guard configuration.profileName.count <= 128 else {
            throw ConfigurationError.invalidText("profileName")
        }
        guard configuration.endpoints.count <= 64 else {
            throw ConfigurationError.tooManyComponents("endpoints")
        }
        guard configuration.pipeline.videoStages.count <= 16 else {
            throw ConfigurationError.tooManyComponents("video stages")
        }
        guard configuration.privacy.grants.count <= 64,
              configuration.privacy.allowedHosts.count <= 64 else {
            throw ConfigurationError.tooManyComponents("privacy entries")
        }
        guard configuration.capture.width > 0, configuration.capture.height > 0 else {
            throw ConfigurationError.invalidCaptureDimensions
        }
        let supportedSizes = [(640, 480), (1_280, 720), (1_920, 1_080)]
        guard supportedSizes.contains(where: {
            $0.0 == configuration.capture.width && $0.1 == configuration.capture.height
        }) else {
            throw ConfigurationError.unsupportedVirtualCameraFormat
        }
        guard [15, 30, 60].contains(configuration.capture.framesPerSecond) else {
            throw ConfigurationError.invalidFrameRate
        }
        guard configuration.capture.audioSampleRate.isFinite,
              (8_000...192_000).contains(configuration.capture.audioSampleRate),
              (1...2).contains(configuration.capture.audioChannels),
              configuration.capture.microphoneGain.isFinite,
              configuration.capture.speechGain.isFinite,
              (0...8).contains(configuration.capture.microphoneGain),
              (0...8).contains(configuration.capture.speechGain) else {
            throw ConfigurationError.invalidAudioConfiguration
        }

        var endpointIDs = Set<String>()
        for endpoint in configuration.endpoints {
            guard !endpoint.id.isEmpty, endpoint.id.count <= 128 else {
                throw ConfigurationError.invalidText("endpoint.id")
            }
            guard endpointIDs.insert(endpoint.id).inserted else {
                throw ConfigurationError.duplicateEndpointID(endpoint.id)
            }
            guard (endpoint.model?.count ?? 0) <= 512,
                  (endpoint.path?.count ?? 0) <= 2_048,
                  endpoint.auth.header.count <= 128,
                  endpoint.auth.prefix.count <= 128,
                  (endpoint.auth.reference?.count ?? 0) <= 512 else {
                throw ConfigurationError.invalidText("endpoint.\(endpoint.id)")
            }
            guard endpoint.timeoutSeconds.isFinite,
                  (0.1...600).contains(endpoint.timeoutSeconds) else {
                throw ConfigurationError.invalidTimeout(endpoint.id)
            }
            try validateOptions(endpoint.options, endpointID: endpoint.id)
            guard let scheme = endpoint.baseURL.scheme?.lowercased(),
                  ["http", "https"].contains(scheme),
                  endpoint.baseURL.host != nil,
                  endpoint.baseURL.user == nil,
                  endpoint.baseURL.password == nil,
                  endpoint.baseURL.query == nil,
                  endpoint.baseURL.fragment == nil else {
                throw ConfigurationError.invalidEndpointURL(endpoint.id)
            }
            if endpoint.auth.kind != .none {
                let reference = endpoint.auth.reference?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !reference.isEmpty,
                      reference.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                      !Self.looksLikeSecret(reference) else {
                    throw ConfigurationError.invalidSecretReference(endpoint.id)
                }
            }
            guard !Self.pathOrOptionsContainCredentials(endpoint.path, options: endpoint.options) else {
                throw ConfigurationError.invalidSecretReference(endpoint.id)
            }
            if !EndpointLocation.isLoopback(endpoint.baseURL), endpoint.baseURL.scheme?.lowercased() != "https" {
                throw ConfigurationError.insecureRemoteEndpoint(endpoint.id)
            }
        }

        var stageIDs = Set<String>()
        for stage in configuration.pipeline.videoStages {
            guard !stage.id.isEmpty,
                  stage.id.count <= 128,
                  (stage.prompt?.count ?? 0) <= AICameraContentLimits.promptCharacters else {
                throw ConfigurationError.invalidText("video stage")
            }
            guard stageIDs.insert(stage.id).inserted else {
                throw ConfigurationError.duplicateStageID(stage.id)
            }
            guard stage.maximumRateHz.isFinite,
                  (0.01...60).contains(stage.maximumRateHz),
                  (50...60_000).contains(stage.maximumFrameAgeMilliseconds) else {
                throw ConfigurationError.invalidRate(stage.id)
            }
            try validateOptions(stage.options, endpointID: "stage.\(stage.id)")
            guard stage.enabled else { continue }
            switch stage.kind {
            case .handGesture:
                break
            case .objectDetection:
                if stage.options["provider"]?.stringValue == "builtin" {
                    guard stage.endpointID == nil else {
                        throw ConfigurationError.invalidText("built-in object detection endpoint")
                    }
                } else {
                    try requireEndpoint(stage.endpointID, for: stage.id, adapters: [.kortexaDetection], endpoints: configuration.endpoints)
                }
            case .visionLanguage:
                try requireEndpoint(stage.endpointID, for: stage.id, adapters: [.openAIVision], endpoints: configuration.endpoints)
            }
        }

        let conversation = configuration.pipeline.conversation
        let wakePhrase = conversation.wakePhrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard conversation.systemPrompt.count <= AICameraContentLimits.promptCharacters,
              conversation.speechVoice.count <= AICameraContentLimits.labelCharacters,
              (conversation.speechInstructions?.count ?? 0) <= AICameraContentLimits.promptCharacters,
              conversation.wakePhrase.count <= AICameraContentLimits.labelCharacters,
              conversation.activationMode != .wakePhrase
                || (!wakePhrase.isEmpty && WakePhraseGate.hasMatchableTokens(wakePhrase)) else {
            throw ConfigurationError.invalidText("conversation")
        }
        let translation = configuration.pipeline.translation
        guard translation.model.count <= AICameraContentLimits.labelCharacters,
              translation.sourceLanguage.count <= AICameraContentLimits.labelCharacters,
              translation.targetLanguage.count <= AICameraContentLimits.labelCharacters,
              !translation.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translation.sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !translation.targetLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ConfigurationError.invalidText("translation")
        }
        guard conversation.utteranceSeconds.isFinite,
              conversation.gestureCooldownSeconds.isFinite,
              conversation.wakeWindowSeconds.isFinite,
              (0.5...30).contains(conversation.utteranceSeconds),
              (0.2...3_600).contains(conversation.gestureCooldownSeconds),
              (1...30).contains(conversation.wakeWindowSeconds) else {
            throw ConfigurationError.invalidRate("conversation")
        }
        let scriptOverlay = configuration.overlays.script
        guard configuration.overlays.resultTTLSeconds.isFinite,
              (0.1...3_600).contains(configuration.overlays.resultTTLSeconds),
              (1_024...1_048_576).contains(scriptOverlay.maxScriptBytes),
              (1...60).contains(scriptOverlay.maximumFps),
              scriptOverlay.defaultTTLSeconds.isFinite,
              (1...3_600).contains(scriptOverlay.defaultTTLSeconds),
              scriptOverlay.maximumTTLSeconds.isFinite,
              (1...3_600).contains(scriptOverlay.maximumTTLSeconds),
              scriptOverlay.defaultTTLSeconds <= scriptOverlay.maximumTTLSeconds else {
            throw ConfigurationError.invalidOverlayConfiguration
        }
        if conversation.transcriptionEnabled {
            try requireEndpoint(
                conversation.transcriptionEndpointID,
                for: "conversation.asr",
                adapters: [.openAITranscription, .kortexaPCMTranscription],
                endpoints: configuration.endpoints
            )
        }
        if conversation.enabled {
            if conversation.realtimeEnabled {
                try requireEndpoint(
                    conversation.realtimeEndpointID,
                    for: "conversation.realtime",
                    adapters: [.openAIRealtime],
                    endpoints: configuration.endpoints
                )
            }
            if let id = conversation.agentEndpointID {
                try requireEndpoint(id, for: "conversation.agent", adapters: [.openAIChat], endpoints: configuration.endpoints)
            }
            if let id = conversation.speechEndpointID {
                try requireEndpoint(id, for: "conversation.tts", adapters: [.openAISpeech], endpoints: configuration.endpoints)
            }
        }

        var grantedEndpointIDs = Set<String>()
        for grant in configuration.privacy.grants {
            guard endpointIDs.contains(grant.endpointID) else {
                throw ConfigurationError.privacyGrantReferencesMissingEndpoint(grant.endpointID)
            }
            guard grantedEndpointIDs.insert(grant.endpointID).inserted else {
                throw ConfigurationError.duplicatePrivacyGrant(grant.endpointID)
            }
        }
        guard !configuration.privacy.persistMedia else {
            throw ConfigurationError.mediaPersistenceUnsupported
        }
    }

    private static func validateOptions(
        _ options: [String: JSONValue],
        endpointID: String
    ) throws {
        func validate(_ value: JSONValue, path: String) throws {
            switch value {
            case let .number(number):
                guard number.isFinite, abs(number) <= 1_000_000_000_000 else {
                    throw ConfigurationError.invalidOption(endpointID: endpointID, option: path)
                }
            case let .string(string):
                guard string.count <= 65_536 else {
                    throw ConfigurationError.invalidOption(endpointID: endpointID, option: path)
                }
            case let .object(object):
                for (key, nested) in object { try validate(nested, path: "\(path).\(key)") }
            case let .array(array):
                for (index, nested) in array.enumerated() { try validate(nested, path: "\(path)[\(index)]") }
            default: break
            }
        }
        for (key, value) in options { try validate(value, path: key) }

        if let temperature = options["temperature"]?.numberValue,
           !(0...2).contains(temperature) {
            throw ConfigurationError.invalidOption(endpointID: endpointID, option: "temperature")
        }
        if let maxTokens = options["max_tokens"]?.numberValue,
           !(1...1_000_000).contains(maxTokens) {
            throw ConfigurationError.invalidOption(endpointID: endpointID, option: "max_tokens")
        }
        if let confidence = options["confidence"]?.numberValue,
           !(0...1).contains(confidence) {
            throw ConfigurationError.invalidOption(endpointID: endpointID, option: "confidence")
        }
    }

    private static let credentialKeys = [
        "api_key", "apikey", "access_token", "token", "secret", "password", "authorization",
    ]

    private static func looksLikeSecret(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return lowered.contains("bearer ")
            || lowered.hasPrefix("sk-")
            || lowered.hasPrefix("ghp_")
            || lowered.hasPrefix("github_pat_")
    }

    private static func pathOrOptionsContainCredentials(
        _ path: String?,
        options: [String: JSONValue]
    ) -> Bool {
        if let path {
            let lowered = path.lowercased()
            if credentialKeys.contains(where: { lowered.contains("\($0)=") }) { return true }
        }
        func containsCredential(_ values: [String: JSONValue]) -> Bool {
            for (key, value) in values {
                let normalizedKey = key.lowercased().replacingOccurrences(of: "-", with: "_")
                if credentialKeys.contains(normalizedKey)
                    || normalizedKey.hasSuffix("_api_key")
                    || normalizedKey.hasSuffix("_secret")
                    || normalizedKey.hasSuffix("_password") {
                    return true
                }
                switch value {
                case let .string(string) where looksLikeSecret(string): return true
                case let .object(object) where containsCredential(object): return true
                case let .array(array):
                    for item in array {
                        if case let .object(object) = item, containsCredential(object) { return true }
                        if case let .string(string) = item, looksLikeSecret(string) { return true }
                    }
                default: break
                }
            }
            return false
        }
        return containsCredential(options)
    }

    private static func requireEndpoint(
        _ endpointID: String?,
        for stageID: String,
        adapters: Set<AdapterKind>,
        endpoints: [EndpointConfiguration]
    ) throws {
        guard let endpointID, let endpoint = endpoints.first(where: { $0.id == endpointID }) else {
            throw ConfigurationError.missingEndpoint(stageID: stageID, endpointID: endpointID ?? "<unset>")
        }
        guard adapters.contains(endpoint.adapter) else {
            throw ConfigurationError.incompatibleEndpoint(stageID: stageID, adapter: endpoint.adapter)
        }
    }
}

public enum EndpointLocation {
    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }
}

public struct ConfigurationStore: Sendable {
    public static let maximumProfileBytes = 1_024 * 1_024
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> AICameraConfiguration {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumProfileBytes {
            throw ConfigurationError.profileTooLarge
        }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= Self.maximumProfileBytes else {
            throw ConfigurationError.profileTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let configuration = try decoder.decode(AICameraConfiguration.self, from: data)
        try ConfigurationValidator.validate(configuration)
        return configuration
    }

    public func save(_ configuration: AICameraConfiguration) throws {
        try ConfigurationValidator.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(configuration)
        guard data.count <= Self.maximumProfileBytes else {
            throw ConfigurationError.profileTooLarge
        }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: fileURL.path
        )
    }
}
