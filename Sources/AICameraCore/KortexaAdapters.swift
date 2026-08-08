import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct KortexaDetectionClient: DetectionClient {
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

    public func detect(_ input: DetectionRequest) async throws -> [Detection] {
        try privacy.authorize(endpoint: endpoint, data: [.rawFrame])
        let boundary = "AICamera-\(UUID().uuidString)"
        let confidence = input.confidence.isFinite ? min(1, max(0, input.confidence)) : 0.25
        var fields = [("confidence", String(confidence))]
        if let model = endpoint.model { fields.append(("model", model)) }
        var request = try await EndpointRequestBuilder(endpoint: endpoint, secrets: secrets).request(path: "/detect")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = multipartBody(
            fields: fields,
            fileField: "file",
            fileName: "frame.jpg",
            mimeType: "image/jpeg",
            fileData: input.jpegData,
            boundary: boundary
        )
        let (data, response) = try await transport.data(for: request)
        let checked = try checkedResponse(data, response)
        guard let root = try JSONSerialization.jsonObject(with: checked) as? [String: Any],
              let rawDetections = root["detections"] as? [[String: Any]] else {
            throw HTTPAdapterError.invalidResponse("missing detections array")
        }
        let width = max(Double(input.imageWidth), 1)
        let height = max(Double(input.imageHeight), 1)
        return rawDetections.prefix(AICameraContentLimits.detections).compactMap { item in
            guard let label = item["class"] as? String,
                  let confidence = item["confidence"] as? Double,
                  let bbox = item["bbox"] as? [Double], bbox.count == 4 else { return nil }
            let x1 = min(max(bbox[0] / width, 0), 1)
            let y1 = min(max(bbox[1] / height, 0), 1)
            let x2 = min(max(bbox[2] / width, 0), 1)
            let y2 = min(max(bbox[3] / height, 0), 1)
            return Detection(
                label: label.aicameraLimited(to: AICameraContentLimits.labelCharacters),
                classID: item["class_id"] as? Int,
                confidence: confidence,
                boundingBox: .init(x: x1, y: y1, width: max(0, x2 - x1), height: max(0, y2 - y1)),
                depthMeters: item["depth_median_m"] as? Double
            )
        }
    }
}

/// Non-streaming raw-PCM adapter for services that implement Kortexa's `/transcribe/pcm` route.
public struct KortexaPCMTranscriptionClient: TranscriptionClient {
    public let endpoint: EndpointConfiguration
    public let transport: any HTTPTransport
    public let secrets: any SecretResolver
    public let privacy: PrivacyGate
    public let sampleRate: Int

    public init(
        endpoint: EndpointConfiguration,
        sampleRate: Int = 16_000,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        secrets: any SecretResolver = EnvironmentSecretResolver(),
        privacy: PrivacyGate
    ) {
        self.endpoint = endpoint; self.sampleRate = sampleRate
        self.transport = transport; self.secrets = secrets; self.privacy = privacy
    }

    public func transcribe(_ input: TranscriptionRequest) async throws -> TranscriptEvent {
        try privacy.authorize(endpoint: endpoint, data: [.rawAudio])
        var requestEndpoint = endpoint
        requestEndpoint.path = nil
        var path = endpoint.path ?? "/transcribe/pcm"
        path += path.contains("?") ? "&sample_rate=\(sampleRate)" : "?sample_rate=\(sampleRate)"
        let queryValueCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        if let language = input.language?.addingPercentEncoding(withAllowedCharacters: queryValueCharacters) {
            path += "&language=\(language)"
        }
        var request = try await EndpointRequestBuilder(endpoint: requestEndpoint, secrets: secrets).request(path: path)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = try WAVFile.pcm16Samples(from: input.wavData)
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
