import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AgentRequest: Equatable, Sendable {
    public var systemPrompt: String
    public var userText: String
    public var sceneContext: String?

    public init(systemPrompt: String, userText: String, sceneContext: String? = nil) {
        self.systemPrompt = systemPrompt
        self.userText = userText
        self.sceneContext = sceneContext
    }
}

public struct VisionRequest: Equatable, Sendable {
    public var jpegData: Data
    public var prompt: String
    public init(jpegData: Data, prompt: String) { self.jpegData = jpegData; self.prompt = prompt }
}

public struct DetectionRequest: Equatable, Sendable {
    public var jpegData: Data
    public var imageWidth: Int
    public var imageHeight: Int
    public var confidence: Double

    public init(jpegData: Data, imageWidth: Int, imageHeight: Int, confidence: Double = 0.25) {
        self.jpegData = jpegData
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.confidence = confidence
    }
}

public struct TranscriptionRequest: Equatable, Sendable {
    public var wavData: Data
    public var language: String?
    public init(wavData: Data, language: String? = nil) { self.wavData = wavData; self.language = language }
}

public struct SpeechRequest: Equatable, Sendable {
    public var text: String
    public var voice: String
    public var instructions: String?
    public var responseFormat: String
    public var speed: Double

    public init(
        text: String,
        voice: String,
        instructions: String? = nil,
        responseFormat: String = "wav",
        speed: Double = 1
    ) {
        self.text = text
        self.voice = voice
        self.instructions = instructions
        self.responseFormat = responseFormat
        self.speed = speed
    }
}

public protocol AgentClient: Sendable {
    func respond(to request: AgentRequest) async throws -> String
}

public protocol VisionClient: Sendable {
    func analyze(_ request: VisionRequest) async throws -> String
}

public protocol DetectionClient: Sendable {
    func detect(_ request: DetectionRequest) async throws -> [Detection]
}

public protocol TranscriptionClient: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptEvent
}

public protocol SpeechClient: Sendable {
    func synthesize(_ request: SpeechRequest) async throws -> Data
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class HTTPRequestCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false

    func install(_ task: URLSessionTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}

private final class CappedRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Result = Swift.Result<(Data, HTTPURLResponse), Error>

    private let maximumBytes: Int
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var response: HTTPURLResponse?
    private var body = Data()
    private var finished = false
    weak var session: URLSession?

    init(
        maximumBytes: Int,
        continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
    ) {
        self.maximumBytes = maximumBytes
        self.continuation = continuation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // A redirect can move a POST body to a host that the privacy gate never authorized.
        completionHandler(nil)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(HTTPAdapterError.nonHTTPResponse))
            return
        }
        if response.expectedContentLength > Int64(maximumBytes) {
            completionHandler(.cancel)
            finish(.failure(HTTPAdapterError.responseTooLarge(maximumBytes)))
            return
        }
        self.response = response
        if response.expectedContentLength > 0 {
            body.reserveCapacity(min(maximumBytes, Int(response.expectedContentLength)))
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard data.count <= maximumBytes - body.count else {
            dataTask.cancel()
            finish(.failure(HTTPAdapterError.responseTooLarge(maximumBytes)))
            return
        }
        body.append(data)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            finish(.failure(CancellationError()))
        } else if let error {
            finish(.failure(error))
        } else if let response {
            finish(.success((body, response)))
        } else {
            finish(.failure(HTTPAdapterError.nonHTTPResponse))
        }
    }

    private func finish(_ result: Result) {
        guard !finished else { return }
        finished = true
        let continuation = self.continuation
        self.continuation = nil
        switch result {
        case let .success(value): continuation?.resume(returning: value)
        case let .failure(error): continuation?.resume(throwing: error)
        }
        session?.invalidateAndCancel()
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    public static let defaultMaximumResponseBytes = 32 * 1_024 * 1_024

    private let maximumResponseBytes: Int
    private let configuration: URLSessionConfiguration

    /// Production requests use a fresh ephemeral session, no persistent cache/cookies, no
    /// redirects, and a hard cumulative response limit. A custom configuration is for tests.
    public init(
        maximumResponseBytes: Int = URLSessionHTTPTransport.defaultMaximumResponseBytes,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
        let provided = configuration ?? .ephemeral
        let configuration = (provided.copy() as? URLSessionConfiguration) ?? provided
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        self.configuration = configuration
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let cancellation = HTTPRequestCancellationBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delegate = CappedRequestDelegate(
                    maximumBytes: maximumResponseBytes,
                    continuation: continuation
                )
                let queue = OperationQueue()
                queue.maxConcurrentOperationCount = 1
                queue.qualityOfService = .userInitiated
                let session = URLSession(
                    configuration: configuration,
                    delegate: delegate,
                    delegateQueue: queue
                )
                delegate.session = session
                let task = session.dataTask(with: request)
                cancellation.install(task)
                task.resume()
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

public protocol SecretResolver: Sendable {
    func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String?
}

public struct EnvironmentSecretResolver: SecretResolver {
    public var environment: [String: String]

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.environment = environment
    }

    public func resolve(_ configuration: EndpointAuthConfiguration) async throws -> String? {
        switch configuration.kind {
        case .none: return nil
        case .bearerEnvironment, .apiKeyEnvironment:
            guard let name = configuration.reference, let secret = environment[name], !secret.isEmpty else {
                throw SecretResolverError.missingReference(configuration.reference ?? "<unset>")
            }
            return secret
        case .bearerKeychain, .apiKeyKeychain:
            throw SecretResolverError.unsupportedSource("Keychain resolution must be supplied by the host app")
        }
    }
}

public enum SecretResolverError: LocalizedError, Equatable {
    case missingReference(String)
    case unsupportedSource(String)

    public var errorDescription: String? {
        switch self {
        case let .missingReference(reference): return "No secret was found for '\(reference)'."
        case let .unsupportedSource(message): return message
        }
    }
}

public enum HTTPAdapterError: LocalizedError, Equatable {
    case invalidURL(String)
    case nonHTTPResponse
    case httpStatus(Int, String)
    case invalidResponse(String)
    case missingModel(String)
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value): return "Invalid endpoint URL: \(value)"
        case .nonHTTPResponse: return "The endpoint did not return an HTTP response."
        case let .httpStatus(status, message): return "Endpoint returned HTTP \(status): \(message)"
        case let .invalidResponse(message): return "The endpoint response was invalid: \(message)"
        case let .missingModel(endpoint): return "Endpoint '\(endpoint)' requires a model name."
        case let .responseTooLarge(limit): return "Endpoint response exceeded the \(limit)-byte safety limit."
        }
    }
}
