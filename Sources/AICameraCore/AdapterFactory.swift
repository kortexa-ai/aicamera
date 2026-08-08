import Foundation

public enum AdapterFactoryError: LocalizedError, Equatable {
    case adapterMismatch(expected: String, actual: AdapterKind)

    public var errorDescription: String? {
        switch self {
        case let .adapterMismatch(expected, actual):
            return "Expected \(expected) adapter but endpoint uses \(actual.rawValue)."
        }
    }
}

public struct AdapterFactory: Sendable {
    public var transport: any HTTPTransport
    public var secrets: any SecretResolver
    public var privacy: PrivacyGate

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func agent(for endpoint: EndpointConfiguration) throws -> any AgentClient {
        guard endpoint.adapter == .openAIChat else {
            throw AdapterFactoryError.adapterMismatch(expected: "agent", actual: endpoint.adapter)
        }
        return OpenAIAgentClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
    }

    public func vision(for endpoint: EndpointConfiguration) throws -> any VisionClient {
        guard endpoint.adapter == .openAIVision else {
            throw AdapterFactoryError.adapterMismatch(expected: "vision", actual: endpoint.adapter)
        }
        return OpenAIVisionClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
    }

    public func detection(for endpoint: EndpointConfiguration) throws -> any DetectionClient {
        guard endpoint.adapter == .kortexaDetection else {
            throw AdapterFactoryError.adapterMismatch(expected: "detection", actual: endpoint.adapter)
        }
        return KortexaDetectionClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
    }

    public func transcription(for endpoint: EndpointConfiguration) throws -> any TranscriptionClient {
        switch endpoint.adapter {
        case .openAITranscription:
            return OpenAITranscriptionClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
        case .kortexaPCMTranscription:
            return KortexaPCMTranscriptionClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
        default:
            throw AdapterFactoryError.adapterMismatch(expected: "transcription", actual: endpoint.adapter)
        }
    }

    public func speech(for endpoint: EndpointConfiguration) throws -> any SpeechClient {
        guard endpoint.adapter == .openAISpeech else {
            throw AdapterFactoryError.adapterMismatch(expected: "speech", actual: endpoint.adapter)
        }
        return OpenAISpeechClient(endpoint: endpoint, transport: transport, secrets: secrets, privacy: privacy)
    }
}
