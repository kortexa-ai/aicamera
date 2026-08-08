import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct OpenAIAgentClient: AgentClient {
    public let endpoint: EndpointConfiguration
    public let transport: any HTTPTransport
    public let secrets: any SecretResolver
    public let privacy: PrivacyGate

    public init(
        endpoint: EndpointConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.endpoint = endpoint; self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func respond(to input: AgentRequest) async throws -> String {
        try privacy.authorize(endpoint: endpoint, data: [.promptText, .transcript, .sceneMetadata])
        guard let model = endpoint.model else { throw HTTPAdapterError.missingModel(endpoint.id) }
        var userText = input.userText
        if let scene = input.sceneContext, !scene.isEmpty { userText += "\n\nCurrent scene context:\n\(scene)" }
        let options = endpoint.options
        var payload: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": input.systemPrompt.aicameraLimited(to: AICameraContentLimits.promptCharacters)],
                ["role": "user", "content": userText],
            ],
            "stream": false,
        ]
        if let temperature = options["temperature"]?.numberValue, temperature.isFinite {
            payload["temperature"] = min(2, max(0, temperature))
        }
        if let maxTokens = options["max_tokens"]?.numberValue, maxTokens.isFinite {
            payload["max_tokens"] = Int(min(1_000_000, max(1, maxTokens)))
        }

        var request = try await EndpointRequestBuilder(endpoint: endpoint, secrets: secrets).request(path: "/v1/chat/completions")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await transport.data(for: request)
        return try firstOpenAIMessageText(
            from: checkedResponse(data, response),
            maximumCharacters: AICameraContentLimits.agentCharacters
        )
    }
}

public struct OpenAIVisionClient: VisionClient {
    public let endpoint: EndpointConfiguration
    public let transport: any HTTPTransport
    public let secrets: any SecretResolver
    public let privacy: PrivacyGate

    public init(
        endpoint: EndpointConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.endpoint = endpoint; self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func analyze(_ input: VisionRequest) async throws -> String {
        try privacy.authorize(endpoint: endpoint, data: [.rawFrame, .promptText])
        guard let model = endpoint.model else { throw HTTPAdapterError.missingModel(endpoint.id) }
        let imageURL = "data:image/jpeg;base64,\(input.jpegData.base64EncodedString())"
        let payload: [String: Any] = [
            "model": model,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "text", "text": input.prompt.aicameraLimited(to: AICameraContentLimits.promptCharacters)],
                    ["type": "image_url", "image_url": ["url": imageURL]],
                ],
            ]],
            "stream": false,
        ]
        var request = try await EndpointRequestBuilder(endpoint: endpoint, secrets: secrets).request(path: "/v1/chat/completions")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await transport.data(for: request)
        return try firstOpenAIMessageText(
            from: checkedResponse(data, response),
            maximumCharacters: AICameraContentLimits.sceneTextCharacters
        )
    }
}

public struct OpenAITranscriptionClient: TranscriptionClient {
    public let endpoint: EndpointConfiguration
    public let transport: any HTTPTransport
    public let secrets: any SecretResolver
    public let privacy: PrivacyGate

    public init(
        endpoint: EndpointConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.endpoint = endpoint; self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func transcribe(_ input: TranscriptionRequest) async throws -> TranscriptEvent {
        try privacy.authorize(endpoint: endpoint, data: [.rawAudio])
        let boundary = "AICamera-\(UUID().uuidString)"
        var fields: [(String, String)] = [("model", endpoint.model ?? "default"), ("response_format", "json")]
        if let language = input.language { fields.append(("language", language)) }
        var request = try await EndpointRequestBuilder(endpoint: endpoint, secrets: secrets).request(path: "/v1/audio/transcriptions")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            fields: fields,
            fileField: "file",
            fileName: "audio.wav",
            mimeType: "audio/wav",
            fileData: input.wavData,
            boundary: boundary
        )
        let (data, response) = try await transport.data(for: request)
        let checked = try checkedResponse(data, response)
        guard let root = try JSONSerialization.jsonObject(with: checked) as? [String: Any],
              let text = root["text"] as? String else {
            throw HTTPAdapterError.invalidResponse("missing transcription text")
        }
        return TranscriptEvent(
            text: text.aicameraLimited(to: AICameraContentLimits.transcriptCharacters),
            mode: .final
        )
    }
}

public struct OpenAISpeechClient: SpeechClient {
    public let endpoint: EndpointConfiguration
    public let transport: any HTTPTransport
    public let secrets: any SecretResolver
    public let privacy: PrivacyGate

    public init(
        endpoint: EndpointConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.endpoint = endpoint; self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func synthesize(_ input: SpeechRequest) async throws -> Data {
        try privacy.authorize(endpoint: endpoint, data: [.promptText])
        guard let model = endpoint.model else { throw HTTPAdapterError.missingModel(endpoint.id) }
        var payload: [String: Any] = [
            "model": model,
            "input": input.text.aicameraLimited(to: AICameraContentLimits.agentCharacters),
            "voice": input.voice.aicameraLimited(to: AICameraContentLimits.labelCharacters),
            "response_format": input.responseFormat,
            "speed": input.speed,
        ]
        if let instructions = input.instructions {
            payload["instructions"] = instructions.aicameraLimited(to: AICameraContentLimits.promptCharacters)
        }
        var request = try await EndpointRequestBuilder(endpoint: endpoint, secrets: secrets).request(path: "/v1/audio/speech")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, response) = try await transport.data(for: request)
        return try checkedResponse(data, response)
    }
}
