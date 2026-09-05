import Foundation

public struct AICameraConfiguration: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var profileName: String
    public var capture: CaptureConfiguration
    public var endpoints: [EndpointConfiguration]
    public var pipeline: PipelineConfiguration
    public var overlays: OverlayConfiguration
    public var privacy: PrivacyConfiguration

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        profileName: String = "Default",
        capture: CaptureConfiguration = .init(),
        endpoints: [EndpointConfiguration] = [],
        pipeline: PipelineConfiguration = .init(),
        overlays: OverlayConfiguration = .init(),
        privacy: PrivacyConfiguration = .init()
    ) {
        self.schemaVersion = schemaVersion
        self.profileName = profileName
        self.capture = capture
        self.endpoints = endpoints
        self.pipeline = pipeline
        self.overlays = overlays
        self.privacy = privacy
    }

    public static let `default` = AICameraConfiguration()
}

public struct CaptureConfiguration: Codable, Equatable, Sendable {
    public var videoDeviceID: String?
    public var audioDeviceID: String?
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int
    public var mirrorVideo: Bool
    public var audioSampleRate: Double
    public var audioChannels: Int
    /// Core Audio device UID that receives the mixed mic and TTS signal.
    public var virtualAudioOutputDeviceID: String?
    public var microphoneGain: Double
    public var speechGain: Double

    public init(
        videoDeviceID: String? = nil,
        audioDeviceID: String? = nil,
        width: Int = 1280,
        height: Int = 720,
        framesPerSecond: Int = 30,
        mirrorVideo: Bool = false,
        audioSampleRate: Double = 48_000,
        audioChannels: Int = 1,
        virtualAudioOutputDeviceID: String? = "ai.kortexa.aicamera.audio.device",
        microphoneGain: Double = 1,
        speechGain: Double = 1
    ) {
        self.videoDeviceID = videoDeviceID
        self.audioDeviceID = audioDeviceID
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.mirrorVideo = mirrorVideo
        self.audioSampleRate = audioSampleRate
        self.audioChannels = audioChannels
        self.virtualAudioOutputDeviceID = virtualAudioOutputDeviceID
        self.microphoneGain = microphoneGain
        self.speechGain = speechGain
    }
}

public enum AdapterKind: String, Codable, CaseIterable, Sendable {
    case openAIChat
    case openAIVision
    case openAITranscription
    case openAISpeech
    case openAIRealtime
    case kortexaDetection
    case kortexaPCMTranscription
}

public enum EndpointAuthKind: String, Codable, CaseIterable, Sendable {
    case none
    case bearerEnvironment
    case apiKeyEnvironment
    case bearerKeychain
    case apiKeyKeychain
}

public struct EndpointAuthConfiguration: Codable, Equatable, Sendable {
    public var kind: EndpointAuthKind
    /// Environment variable name or Keychain account name. Never a secret value.
    public var reference: String?
    public var header: String
    public var prefix: String

    public init(
        kind: EndpointAuthKind = .none,
        reference: String? = nil,
        header: String = "Authorization",
        prefix: String = "Bearer "
    ) {
        self.kind = kind
        self.reference = reference
        self.header = header
        self.prefix = prefix
    }
}

public struct EndpointConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var adapter: AdapterKind
    public var baseURL: URL
    /// Optional path override. The adapter's compatible default path is used when nil.
    public var path: String?
    public var model: String?
    public var auth: EndpointAuthConfiguration
    public var timeoutSeconds: Double
    public var options: [String: JSONValue]

    public init(
        id: String,
        adapter: AdapterKind,
        baseURL: URL,
        path: String? = nil,
        model: String? = nil,
        auth: EndpointAuthConfiguration = .init(),
        timeoutSeconds: Double = 20,
        options: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.adapter = adapter
        self.baseURL = baseURL
        self.path = path
        self.model = model
        self.auth = auth
        self.timeoutSeconds = timeoutSeconds
        self.options = options
    }
}

public enum VideoStageKind: String, Codable, CaseIterable, Sendable {
    case handGesture
    case objectDetection
    case visionLanguage
}

public struct VideoStageConfiguration: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: VideoStageKind
    public var enabled: Bool
    public var endpointID: String?
    public var maximumRateHz: Double
    public var maximumFrameAgeMilliseconds: Int
    public var prompt: String?
    public var options: [String: JSONValue]

    public init(
        id: String,
        kind: VideoStageKind,
        enabled: Bool = true,
        endpointID: String? = nil,
        maximumRateHz: Double = 2,
        maximumFrameAgeMilliseconds: Int = 1_000,
        prompt: String? = nil,
        options: [String: JSONValue] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.enabled = enabled
        self.endpointID = endpointID
        self.maximumRateHz = maximumRateHz
        self.maximumFrameAgeMilliseconds = maximumFrameAgeMilliseconds
        self.prompt = prompt
        self.options = options
    }
}

public enum ConversationActivationMode: String, Codable, CaseIterable, Sendable {
    case wakePhrase
    case alwaysListening
}

public enum TranscriptionProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case whisper
}

public struct ConversationConfiguration: Codable, Equatable, Sendable {
    public static let defaultSystemPrompt = "You are an assistant present in a live camera conversation. Respond briefly and never claim to see facts that are not in the supplied scene context."
    public static let defaultWakePhrase = "Hey Kortexa"

    public var enabled: Bool
    public var realtimeEnabled: Bool
    public var realtimeAuthentication: RealtimeAuthentication
    public var realtimeEndpointID: String?
    public var transcriptionEnabled: Bool
    public var transcriptionEndpointID: String?
    public var transcriptionProvider: TranscriptionProvider
    public var transcriptionWhisperModel: BuiltinWhisperModel
    public var transcriptionLanguage: String
    public var agentEndpointID: String?
    public var speechEndpointID: String?
    public var systemPrompt: String
    public var respondToFinalTranscripts: Bool
    public var activationMode: ConversationActivationMode
    public var wakePhrase: String
    public var wakeWindowSeconds: Double
    public var includeSceneSummary: Bool
    public var speechVoice: String
    public var speechInstructions: String?
    public var utteranceSeconds: Double
    public var bargeIn: Bool
    public var respondToGestures: Bool
    public var gestureCooldownSeconds: Double

    public init(
        enabled: Bool = false,
        realtimeEnabled: Bool = false,
        realtimeAuthentication: RealtimeAuthentication = .apiKey,
        realtimeEndpointID: String? = nil,
        transcriptionEnabled: Bool = false,
        transcriptionEndpointID: String? = nil,
        transcriptionProvider: TranscriptionProvider = .openAI,
        transcriptionWhisperModel: BuiltinWhisperModel = .base,
        transcriptionLanguage: String = "auto",
        agentEndpointID: String? = nil,
        speechEndpointID: String? = nil,
        systemPrompt: String = Self.defaultSystemPrompt,
        respondToFinalTranscripts: Bool = true,
        activationMode: ConversationActivationMode = .wakePhrase,
        wakePhrase: String = Self.defaultWakePhrase,
        wakeWindowSeconds: Double = 8,
        includeSceneSummary: Bool = true,
        speechVoice: String = "aiden",
        speechInstructions: String? = nil,
        utteranceSeconds: Double = 3,
        bargeIn: Bool = true,
        respondToGestures: Bool = true,
        gestureCooldownSeconds: Double = 2
    ) {
        self.enabled = enabled
        self.realtimeEnabled = realtimeEnabled
        self.realtimeAuthentication = realtimeAuthentication
        self.realtimeEndpointID = realtimeEndpointID
        self.transcriptionEnabled = transcriptionEnabled
        self.transcriptionEndpointID = transcriptionEndpointID
        self.transcriptionProvider = transcriptionProvider
        self.transcriptionWhisperModel = transcriptionWhisperModel
        self.transcriptionLanguage = transcriptionLanguage
        self.agentEndpointID = agentEndpointID
        self.speechEndpointID = speechEndpointID
        self.systemPrompt = systemPrompt
        self.respondToFinalTranscripts = respondToFinalTranscripts
        self.activationMode = activationMode
        self.wakePhrase = wakePhrase
        self.wakeWindowSeconds = wakeWindowSeconds
        self.includeSceneSummary = includeSceneSummary
        self.speechVoice = speechVoice
        self.speechInstructions = speechInstructions
        self.utteranceSeconds = utteranceSeconds
        self.bargeIn = bargeIn
        self.respondToGestures = respondToGestures
        self.gestureCooldownSeconds = gestureCooldownSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case realtimeEnabled
        case realtimeAuthentication
        case realtimeEndpointID
        case transcriptionEnabled
        case transcriptionEndpointID
        case transcriptionProvider
        case transcriptionWhisperModel
        case transcriptionLanguage
        case agentEndpointID
        case speechEndpointID
        case systemPrompt
        case respondToFinalTranscripts
        case activationMode
        case wakePhrase
        case wakeWindowSeconds
        case includeSceneSummary
        case speechVoice
        case speechInstructions
        case utteranceSeconds
        case bargeIn
        case respondToGestures
        case gestureCooldownSeconds
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        realtimeEnabled = try container.decodeIfPresent(Bool.self, forKey: .realtimeEnabled) ?? false
        realtimeAuthentication = try container.decodeIfPresent(RealtimeAuthentication.self, forKey: .realtimeAuthentication) ?? .apiKey
        realtimeEndpointID = try container.decodeIfPresent(String.self, forKey: .realtimeEndpointID)
        transcriptionEndpointID = try container.decodeIfPresent(String.self, forKey: .transcriptionEndpointID)
        transcriptionProvider = try container.decodeIfPresent(TranscriptionProvider.self, forKey: .transcriptionProvider) ?? .openAI
        transcriptionWhisperModel = try container.decodeIfPresent(BuiltinWhisperModel.self, forKey: .transcriptionWhisperModel) ?? .base
        transcriptionLanguage = try container.decodeIfPresent(String.self, forKey: .transcriptionLanguage) ?? "auto"
        transcriptionEnabled = try container.decodeIfPresent(Bool.self, forKey: .transcriptionEnabled)
            ?? (transcriptionEndpointID != nil)
        agentEndpointID = try container.decodeIfPresent(String.self, forKey: .agentEndpointID)
        speechEndpointID = try container.decodeIfPresent(String.self, forKey: .speechEndpointID)
        systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
        respondToFinalTranscripts = try container.decode(Bool.self, forKey: .respondToFinalTranscripts)
        // Schema-1 profiles predate wake gating and therefore retain their always-listening behavior.
        activationMode = try container.decodeIfPresent(ConversationActivationMode.self, forKey: .activationMode)
            ?? .alwaysListening
        wakePhrase = try container.decodeIfPresent(String.self, forKey: .wakePhrase) ?? Self.defaultWakePhrase
        wakeWindowSeconds = try container.decodeIfPresent(Double.self, forKey: .wakeWindowSeconds) ?? 8
        includeSceneSummary = try container.decode(Bool.self, forKey: .includeSceneSummary)
        speechVoice = try container.decode(String.self, forKey: .speechVoice)
        speechInstructions = try container.decodeIfPresent(String.self, forKey: .speechInstructions)
        utteranceSeconds = try container.decode(Double.self, forKey: .utteranceSeconds)
        bargeIn = try container.decode(Bool.self, forKey: .bargeIn)
        respondToGestures = try container.decode(Bool.self, forKey: .respondToGestures)
        gestureCooldownSeconds = try container.decode(Double.self, forKey: .gestureCooldownSeconds)
    }
}

public struct PipelineConfiguration: Codable, Equatable, Sendable {
    public var videoStages: [VideoStageConfiguration]
    public var conversation: ConversationConfiguration
    public var translation: TranslationConfiguration

    public init(
        videoStages: [VideoStageConfiguration] = [],
        conversation: ConversationConfiguration = .init(),
        translation: TranslationConfiguration = .init()
    ) {
        self.videoStages = videoStages
        self.conversation = conversation
        self.translation = translation
    }

    private enum CodingKeys: String, CodingKey {
        case videoStages
        case conversation
        case translation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        videoStages = try container.decode([VideoStageConfiguration].self, forKey: .videoStages)
        conversation = try container.decode(ConversationConfiguration.self, forKey: .conversation)
        translation = try container.decodeIfPresent(TranslationConfiguration.self, forKey: .translation) ?? .init()
    }
}

public struct TranslationConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var model: String
    public var sourceLanguage: String
    public var targetLanguage: String

    public init(
        enabled: Bool = false,
        model: String = "hy-mt2-1.8b-q4-k-m",
        sourceLanguage: String = "auto",
        targetLanguage: String = "system"
    ) {
        self.enabled = enabled
        self.model = model
        self.sourceLanguage = sourceLanguage
        self.targetLanguage = targetLanguage
    }
}

/// Bounds for model-rendered overlay scripts (three.js scenes in a hidden WKWebView).
public struct ScriptOverlayConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var maxScriptBytes: Int
    public var maximumFps: Int
    public var defaultTTLSeconds: Double
    public var maximumTTLSeconds: Double
    /// When true, the script can read the current scene snapshot (detections,
    /// gestures, transcript) through the bridge. The data stays local.
    public var allowSceneData: Bool

    public init(
        enabled: Bool = false,
        maxScriptBytes: Int = 65_536,
        maximumFps: Int = 30,
        defaultTTLSeconds: Double = 30,
        maximumTTLSeconds: Double = 60,
        allowSceneData: Bool = false
    ) {
        self.enabled = enabled
        self.maxScriptBytes = maxScriptBytes
        self.maximumFps = maximumFps
        self.defaultTTLSeconds = defaultTTLSeconds
        self.maximumTTLSeconds = maximumTTLSeconds
        self.allowSceneData = allowSceneData
    }
}

public struct OverlayConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var showDetectionBoxes: Bool
    public var showGestureLabels: Bool
    public var showTranscript: Bool
    public var showAgentResponse: Bool
    public var showStatus: Bool
    public var resultTTLSeconds: Double
    public var accentHex: String
    public var script: ScriptOverlayConfiguration

    public init(
        enabled: Bool = false,
        showDetectionBoxes: Bool = true,
        showGestureLabels: Bool = true,
        showTranscript: Bool = true,
        showAgentResponse: Bool = true,
        showStatus: Bool = true,
        resultTTLSeconds: Double = 4,
        accentHex: String = "#59F3C2",
        script: ScriptOverlayConfiguration = .init()
    ) {
        self.enabled = enabled
        self.showDetectionBoxes = showDetectionBoxes
        self.showGestureLabels = showGestureLabels
        self.showTranscript = showTranscript
        self.showAgentResponse = showAgentResponse
        self.showStatus = showStatus
        self.resultTTLSeconds = resultTTLSeconds
        self.accentHex = accentHex
        self.script = script
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        showDetectionBoxes = try container.decode(Bool.self, forKey: .showDetectionBoxes)
        showGestureLabels = try container.decode(Bool.self, forKey: .showGestureLabels)
        showTranscript = try container.decode(Bool.self, forKey: .showTranscript)
        showAgentResponse = try container.decode(Bool.self, forKey: .showAgentResponse)
        showStatus = try container.decode(Bool.self, forKey: .showStatus)
        resultTTLSeconds = try container.decode(Double.self, forKey: .resultTTLSeconds)
        accentHex = try container.decode(String.self, forKey: .accentHex)
        // Schema-1 profiles predate script overlays and keep the disabled default.
        script = try container.decodeIfPresent(ScriptOverlayConfiguration.self, forKey: .script)
            ?? ScriptOverlayConfiguration()
    }
}

public enum NetworkPrivacyMode: String, Codable, CaseIterable, Sendable {
    case localOnly
    case allowListed
}

public enum MediaDataClass: String, Codable, CaseIterable, Hashable, Sendable {
    case rawAudio
    case rawFrame
    case transcript
    case sceneMetadata
    case promptText
}

public struct EndpointPrivacyGrant: Codable, Equatable, Sendable {
    public var endpointID: String
    public var allowedData: Set<MediaDataClass>

    public init(endpointID: String, allowedData: Set<MediaDataClass>) {
        self.endpointID = endpointID
        self.allowedData = allowedData
    }
}

public struct PrivacyConfiguration: Codable, Equatable, Sendable {
    public var networkMode: NetworkPrivacyMode
    /// Exact host names that may receive data when `networkMode` is `allowListed`.
    public var allowedHosts: [String]
    public var grants: [EndpointPrivacyGrant]
    public var persistMedia: Bool

    public init(
        networkMode: NetworkPrivacyMode = .localOnly,
        allowedHosts: [String] = [],
        grants: [EndpointPrivacyGrant] = [],
        persistMedia: Bool = false
    ) {
        self.networkMode = networkMode
        self.allowedHosts = allowedHosts
        self.grants = grants
        self.persistMedia = persistMedia
    }
}
