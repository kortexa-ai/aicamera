import XCTest
@testable import AICameraCore

private struct StubTransport: HTTPTransport {
    let handler: @Sendable (URLRequest) throws -> (Data, HTTPURLResponse)
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) { try handler(request) }
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

final class AdapterTests: XCTestCase {
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

}
