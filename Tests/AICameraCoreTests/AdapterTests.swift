import XCTest
@testable import AICameraCore

private struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try handler(request) }
}

private struct StubStreamingTransport: HTTPStreamingTransport {
    let handler: @Sendable (URLRequest) throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw HTTPAdapterError.invalidResponse("unexpected buffered request")
    }

    func stream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        try handler(request)
    }
}

private struct LegacySpeechClient: SpeechClient {
    func synthesize(_ request: SpeechRequest) async throws -> Data {
        Data(request.responseFormat.utf8)
    }
}

private func stubStream(_ chunks: [Data]) -> AsyncThrowingStream<Data, Error> {
    AsyncThrowingStream(bufferingPolicy: .bufferingOldest(max(1, chunks.count))) { continuation in
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
    }
}

private final class RedirectProbeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var redirectedRequestObserved = false

    static func reset() {
        lock.lock(); redirectedRequestObserved = false; lock.unlock()
    }

    static var leaked: Bool {
        lock.lock(); defer { lock.unlock() }
        return redirectedRequestObserved
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.host == "allowed.example" else {
            Self.lock.lock(); Self.redirectedRequestObserved = true; Self.lock.unlock()
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("leaked".utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://other.example/collect"]
        )!
        client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: URL(string: "https://other.example/collect")!), redirectResponse: response)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class OversizedURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 800))
        client?.urlProtocol(self, didLoad: Data(repeating: 0x42, count: 800))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class BurstStreamingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 3_072))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class HangingStreamingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var didStart = false
    private static var didStop = false

    static func reset() {
        lock.lock(); didStart = false; didStop = false; lock.unlock()
    }

    static var started: Bool {
        lock.lock(); defer { lock.unlock() }
        return didStart
    }

    static var stopped: Bool {
        lock.lock(); defer { lock.unlock() }
        return didStop
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); Self.didStart = true; Self.lock.unlock()
        if request.url?.path == "/pending-response" { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x41]))
    }

    override func stopLoading() {
        Self.lock.lock(); Self.didStop = true; Self.lock.unlock()
    }
}

final class AdapterTests: XCTestCase {
    func testOpenAITranscriptionUsesConfiguredModelAndLanguage() async throws {
        let endpoint = EndpointConfiguration(
            id: "asr",
            adapter: .openAITranscription,
            baseURL: URL(string: "https://api.openai.com")!,
            model: "gpt-transcribe"
        )
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            let body = try XCTUnwrap(request.httpBody)
            let text = try XCTUnwrap(String(data: body, encoding: .utf8))
            XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngpt-transcribe"))
            XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nen"))
            XCTAssertTrue(text.contains("name=\"file\"; filename=\"audio.wav\""))
            let data = try JSONSerialization.data(withJSONObject: ["text": "Hello from the void."])
            return (
                data,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = OpenAITranscriptionClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init(
                networkMode: .allowListed,
                allowedHosts: ["api.openai.com"],
                grants: [.init(endpointID: "asr", allowedData: [.rawAudio])]
            ))
        )

        let transcript = try await client.transcribe(.init(wavData: Data([1, 2, 3]), language: "en"))
        XCTAssertEqual(transcript.text, "Hello from the void.")
        XCTAssertEqual(transcript.mode, .final)
    }

    func testOpenAIChatRequestAndResponse() async throws {
        let endpoint = EndpointConfiguration(
            id: "agent",
            adapter: .openAIChat,
            baseURL: URL(string: "http://127.0.0.1:2030")!,
            model: "small-agent",
            auth: .init(kind: .bearerEnvironment, reference: "TEST_TOKEN")
        )
        let transport = StubTransport { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:2030/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret")
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["model"] as? String, "small-agent")
            let data = try JSONSerialization.data(withJSONObject: [
                "choices": [["message": ["content": "Hello, carbon unit."]]]
            ])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = OpenAIAgentClient(
            endpoint: endpoint,
            transport: transport,
            secrets: EnvironmentSecretResolver(environment: ["TEST_TOKEN": "secret"]),
            privacy: PrivacyGate(configuration: .init())
        )
        let response = try await client.respond(to: .init(systemPrompt: "Be odd", userText: "Hi"))
        XCTAssertEqual(response, "Hello, carbon unit.")
    }

    func testDetectionNormalizesBoundingBoxes() async throws {
        let endpoint = EndpointConfiguration(
            id: "objects",
            adapter: .kortexaDetection,
            baseURL: URL(string: "http://127.0.0.1:4001")!
        )
        let transport = StubTransport { request in
            let data = try JSONSerialization.data(withJSONObject: [
                "detections": [[
                    "class": "cat",
                    "class_id": 15,
                    "confidence": 0.9,
                    "bbox": [100.0, 50.0, 300.0, 250.0],
                    "depth_median_m": 1.5,
                ]]
            ])
            return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let client = KortexaDetectionClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init())
        )
        let results = try await client.detect(.init(jpegData: Data([1, 2]), imageWidth: 400, imageHeight: 300))
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].boundingBox.x, 0.25, accuracy: 0.000_001)
        XCTAssertEqual(results[0].boundingBox.y, 1.0 / 6.0, accuracy: 0.000_001)
        XCTAssertEqual(results[0].boundingBox.width, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(results[0].boundingBox.height, 2.0 / 3.0, accuracy: 0.000_001)
        XCTAssertEqual(results[0].depthMeters, 1.5)
    }

    func testHTTPErrorBodyIsBoundedAndReported() async {
        let endpoint = EndpointConfiguration(
            id: "tts",
            adapter: .openAISpeech,
            baseURL: URL(string: "http://127.0.0.1:4003")!,
            model: "tts"
        )
        let transport = StubTransport { request in
            (Data("not ready".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        }
        let client = OpenAISpeechClient(endpoint: endpoint, transport: transport, privacy: PrivacyGate(configuration: .init()))
        do {
            _ = try await client.synthesize(.init(text: "hello", voice: "aiden"))
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? HTTPAdapterError, .httpStatus(503, "not ready"))
        }
    }

    func testSpeechClientStreamingDefaultWrapsCompleteWAV() async throws {
        let client: any SpeechClient = LegacySpeechClient()
        let result = try await client.synthesizeStream(.init(
            text: "hello",
            voice: "aiden",
            responseFormat: "mp3"
        ))

        XCTAssertEqual(result.format, .wav)
        var chunks: [Data] = []
        for try await chunk in result.chunks { chunks.append(chunk) }
        XCTAssertEqual(chunks, [Data("wav".utf8)])
    }

    func testOpenAISpeechStreamingFallsBackForNonStreamingTransport() async throws {
        let endpoint = EndpointConfiguration(
            id: "tts",
            adapter: .openAISpeech,
            baseURL: URL(string: "http://127.0.0.1:4003")!,
            model: "tts",
            options: ["streamingPCM": .bool(true)]
        )
        let expected = Data("complete wav".utf8)
        let transport = StubTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["response_format"] as? String, "wav")
            XCTAssertNil(json["stream_format"])
            return (
                expected,
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            )
        }
        let client = OpenAISpeechClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init())
        )

        let result = try await client.synthesizeStream(.init(text: "hello", voice: "aiden"))
        XCTAssertEqual(result.format, .wav)
        var chunks: [Data] = []
        for try await chunk in result.chunks { chunks.append(chunk) }
        XCTAssertEqual(chunks, [expected])
    }

    func testOpenAISpeechStreamsPCMWithHeaderMetadata() async throws {
        let endpoint = EndpointConfiguration(
            id: "tts",
            adapter: .openAISpeech,
            baseURL: URL(string: "http://127.0.0.1:4003")!,
            model: "tts",
            options: ["streamingPCM": .bool(true)]
        )
        let expectedChunks = [Data([1, 2]), Data([3, 4])]
        let transport = StubStreamingTransport { request in
            let body = try XCTUnwrap(request.httpBody)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
            XCTAssertEqual(json["response_format"] as? String, "pcm")
            XCTAssertEqual(json["stream_format"] as? String, "audio")
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["x-sample-rate": "32000"]
            )!
            return (stubStream(expectedChunks), response)
        }
        let client = OpenAISpeechClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init())
        )

        let result = try await client.synthesizeStream(.init(text: "hello", voice: "aiden"))
        XCTAssertEqual(
            result.format,
            .pcm16LittleEndian(sampleRate: 32_000, channelCount: 1)
        )
        var chunks: [Data] = []
        for try await chunk in result.chunks { chunks.append(chunk) }
        XCTAssertEqual(chunks, expectedChunks)
    }

    func testOpenAISpeechUsesConfiguredPCMSampleRateWhenHeaderIsAbsent() async throws {
        let endpoint = EndpointConfiguration(
            id: "tts",
            adapter: .openAISpeech,
            baseURL: URL(string: "http://127.0.0.1:4003")!,
            model: "tts",
            options: [
                "streamingPCM": .bool(true),
                "pcmSampleRate": .number(22_050),
            ]
        )
        let transport = StubStreamingTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            return (stubStream([Data([1, 2])]), response)
        }
        let client = OpenAISpeechClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init())
        )

        let result = try await client.synthesizeStream(.init(text: "hello", voice: "aiden"))
        XCTAssertEqual(
            result.format,
            .pcm16LittleEndian(sampleRate: 22_050, channelCount: 1)
        )
    }

    func testOpenAISpeechRejectsUnsafeSampleRateHeader() async {
        let endpoint = EndpointConfiguration(
            id: "tts",
            adapter: .openAISpeech,
            baseURL: URL(string: "http://127.0.0.1:4003")!,
            model: "tts",
            options: ["streamingPCM": .bool(true)]
        )
        let transport = StubStreamingTransport { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["x-sample-rate": "1000000"]
            )!
            return (stubStream([Data([1, 2])]), response)
        }
        let client = OpenAISpeechClient(
            endpoint: endpoint,
            transport: transport,
            privacy: PrivacyGate(configuration: .init())
        )

        do {
            _ = try await client.synthesizeStream(.init(text: "hello", voice: "aiden"))
            XCTFail("Expected an invalid sample rate error")
        } catch {
            XCTAssertEqual(
                error as? HTTPAdapterError,
                .invalidResponse("x-sample-rate must be an integer from 8000 through 192000")
            )
        }
    }

    func testProductionRedirectPolicyFailsClosed() async throws {
        RedirectProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectProbeURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        do {
            let (_, response) = try await transport.data(for: URLRequest(
                url: URL(string: "https://allowed.example/upload")!
            ))
            XCTAssertEqual(response.statusCode, 307)
        } catch {
            // Custom URLProtocol does not always surface the original redirect response after
            // rejection. It must still never issue the second request.
            XCTAssertEqual(error as? HTTPAdapterError, .nonHTTPResponse)
        }
        XCTAssertFalse(RedirectProbeURLProtocol.leaked)
    }

    func testProductionTransportCapsChunkedResponse() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedURLProtocol.self]
        let transport = URLSessionHTTPTransport(maximumResponseBytes: 1_024, configuration: configuration)
        do {
            _ = try await transport.data(for: URLRequest(url: URL(string: "https://allowed.example/large")!))
            XCTFail("Expected the response limit")
        } catch {
            XCTAssertEqual(error as? HTTPAdapterError, .responseTooLarge(1_024))
        }
    }

    func testProductionStreamingTransportRejectsRedirect() async {
        RedirectProbeURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectProbeURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        var failed = false
        do {
            let (chunks, _) = try await transport.stream(for: URLRequest(
                url: URL(string: "https://allowed.example/upload")!
            ))
            for try await _ in chunks {}
        } catch {
            failed = true
        }
        XCTAssertTrue(failed)
        XCTAssertFalse(RedirectProbeURLProtocol.leaked)
    }

    func testProductionStreamingTransportCapsCumulativeBytes() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OversizedURLProtocol.self]
        let transport = URLSessionHTTPTransport(
            maximumResponseBytes: 1_024,
            configuration: configuration
        )
        do {
            let (chunks, _) = try await transport.stream(for: URLRequest(
                url: URL(string: "https://allowed.example/large")!
            ))
            for try await _ in chunks {}
            XCTFail("Expected the response limit")
        } catch {
            XCTAssertEqual(error as? HTTPAdapterError, .responseTooLarge(1_024))
        }
    }

    func testProductionStreamingTransportFailsOnBufferOverflow() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BurstStreamingURLProtocol.self]
        let transport = URLSessionHTTPTransport(
            maximumResponseBytes: 4_096,
            maximumBufferedStreamChunks: 1,
            maximumStreamChunkBytes: 1_024,
            configuration: configuration
        )
        do {
            let (chunks, _) = try await transport.stream(for: URLRequest(
                url: URL(string: "https://allowed.example/burst")!
            ))
            try await Task.sleep(nanoseconds: 20_000_000)
            for try await _ in chunks {}
            XCTFail("Expected bounded stream overflow")
        } catch {
            XCTAssertEqual(error as? HTTPAdapterError, .streamBufferOverflow)
        }
    }

    func testProductionStreamingTransportPropagatesTaskCancellation() async throws {
        HangingStreamingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingStreamingURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        let requestTask = Task {
            try await transport.stream(for: URLRequest(
                url: URL(string: "https://allowed.example/pending-response")!
            ))
        }
        for _ in 0..<40 where !HangingStreamingURLProtocol.started {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(HangingStreamingURLProtocol.started)
        requestTask.cancel()

        do {
            _ = try await requestTask.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        for _ in 0..<20 where !HangingStreamingURLProtocol.stopped {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(HangingStreamingURLProtocol.stopped)
    }

    func testProductionStreamingTransportCancelsStartedBodyConsumer() async throws {
        HangingStreamingURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HangingStreamingURLProtocol.self]
        let transport = URLSessionHTTPTransport(configuration: configuration)
        let consumer = Task {
            let (chunks, _) = try await transport.stream(for: URLRequest(
                url: URL(string: "https://allowed.example/hanging-body")!
            ))
            for try await _ in chunks {}
            try Task.checkCancellation()
        }

        for _ in 0..<40 where !HangingStreamingURLProtocol.started {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(HangingStreamingURLProtocol.started)
        consumer.cancel()

        do {
            try await consumer.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
        for _ in 0..<40 where !HangingStreamingURLProtocol.stopped {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(HangingStreamingURLProtocol.stopped)
    }

}
