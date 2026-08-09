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

public enum SpeechAudioEncoding: String, Equatable, Sendable {
    case wav
    case pcm16LittleEndian
}

public struct SpeechAudioFormat: Equatable, Sendable {
    public var encoding: SpeechAudioEncoding
    /// Raw PCM sample rate. A WAV stream carries its format in the container instead.
    public var sampleRate: Int?
    /// Raw PCM channel count. A WAV stream carries its format in the container instead.
    public var channelCount: Int?

    public init(
        encoding: SpeechAudioEncoding,
        sampleRate: Int? = nil,
        channelCount: Int? = nil
    ) {
        self.encoding = encoding
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public static let wav = SpeechAudioFormat(encoding: .wav)

    public static func pcm16LittleEndian(
        sampleRate: Int,
        channelCount: Int = 1
    ) -> SpeechAudioFormat {
        SpeechAudioFormat(
            encoding: .pcm16LittleEndian,
            sampleRate: sampleRate,
            channelCount: channelCount
        )
    }
}

public struct SpeechAudioStream: Sendable {
    public var format: SpeechAudioFormat
    public var chunks: AsyncThrowingStream<Data, Error>

    public init(
        format: SpeechAudioFormat,
        chunks: AsyncThrowingStream<Data, Error>
    ) {
        self.format = format
        self.chunks = chunks
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
    func synthesizeStream(_ request: SpeechRequest) async throws -> SpeechAudioStream
}

public extension SpeechClient {
    /// Compatibility path for clients that only implement complete WAV synthesis.
    func synthesizeStream(_ request: SpeechRequest) async throws -> SpeechAudioStream {
        var wavRequest = request
        wavRequest.responseFormat = "wav"
        let data = try await synthesize(wavRequest)
        let chunks = AsyncThrowingStream<Data, Error>(bufferingPolicy: .bufferingOldest(1)) { continuation in
            continuation.yield(data)
            continuation.finish()
        }
        return SpeechAudioStream(format: .wav, chunks: chunks)
    }
}

public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Optional transport capability for incrementally delivered response bodies.
/// Implementations must fail rather than silently dropping body chunks.
public protocol HTTPStreamingTransport: HTTPTransport {
    func stream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse)
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

private final class CappedStreamingRequestDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<Data, Error>
    typealias StartResult = (Stream, HTTPURLResponse)

    private static let maximumErrorBodyBytes = 2_048

    private let maximumBytes: Int
    private let maximumChunkBytes: Int
    /// Held only until response headers let `stream(for:)` return. Retaining the stream for the
    /// request lifetime would prevent a caller that drops it from terminating the producer.
    private var stream: Stream?
    private var streamContinuation: Stream.Continuation?
    private var startContinuation: CheckedContinuation<StartResult, Error>?
    private var response: HTTPURLResponse?
    private var errorBody = Data()
    private var receivedBytes = 0
    private var started = false
    private var finished = false
    weak var session: URLSession?

    init(
        maximumBytes: Int,
        maximumChunkBytes: Int,
        stream: Stream,
        streamContinuation: Stream.Continuation,
        startContinuation: CheckedContinuation<StartResult, Error>
    ) {
        self.maximumBytes = maximumBytes
        self.maximumChunkBytes = maximumChunkBytes
        self.stream = stream
        self.streamContinuation = streamContinuation
        self.startContinuation = startContinuation
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Do not allow a streamed POST body to escape the host authorized by the privacy gate.
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
            finish(throwing: HTTPAdapterError.nonHTTPResponse)
            return
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else {
            completionHandler(.cancel)
            finish(throwing: HTTPAdapterError.responseTooLarge(maximumBytes))
            return
        }
        self.response = response
        guard (200..<300).contains(response.statusCode) else {
            completionHandler(.allow)
            return
        }

        guard let stream else {
            completionHandler(.cancel)
            finish(throwing: CancellationError())
            return
        }
        started = true
        let continuation = startContinuation
        startContinuation = nil
        continuation?.resume(returning: (stream, response))
        // The checked continuation now owns the returned stream value; the delegate must not keep
        // another consumer-side reference for the remaining request lifetime.
        self.stream = nil
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard data.count <= maximumBytes - receivedBytes else {
            dataTask.cancel()
            finish(throwing: HTTPAdapterError.responseTooLarge(maximumBytes))
            return
        }
        receivedBytes += data.count

        guard let response, (200..<300).contains(response.statusCode) else {
            let remaining = Self.maximumErrorBodyBytes - errorBody.count
            if remaining > 0 { errorBody.append(data.prefix(remaining)) }
            return
        }

        var offset = data.startIndex
        while offset < data.endIndex, !finished {
            let count = min(maximumChunkBytes, data.distance(from: offset, to: data.endIndex))
            let end = data.index(offset, offsetBy: count)
            let chunk = Data(data[offset..<end])
            switch streamContinuation?.yield(chunk) {
            case .enqueued?:
                break
            case .dropped?:
                // AsyncThrowingStream cannot back-pressure a URLSession delegate. Fail closed
                // instead of silently corrupting PCM when the bounded consumer buffer is full.
                dataTask.cancel()
                finish(throwing: HTTPAdapterError.streamBufferOverflow)
            case .terminated?, nil:
                dataTask.cancel()
                finish(throwing: CancellationError())
            @unknown default:
                dataTask.cancel()
                finish(throwing: HTTPAdapterError.streamBufferOverflow)
            }
            offset = end
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard !finished else { return }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            finish(throwing: CancellationError())
        } else if let error {
            finish(throwing: error)
        } else if let response, !(200..<300).contains(response.statusCode) {
            let body = String(data: errorBody, encoding: .utf8) ?? "<non-text response>"
            finish(throwing: HTTPAdapterError.httpStatus(response.statusCode, body))
        } else if response != nil, started {
            finish()
        } else {
            finish(throwing: HTTPAdapterError.nonHTTPResponse)
        }
    }

    private func finish(throwing error: Error? = nil) {
        guard !finished else { return }
        finished = true
        let startContinuation = self.startContinuation
        self.startContinuation = nil
        self.stream = nil
        let streamContinuation = self.streamContinuation
        self.streamContinuation = nil

        if let startContinuation {
            startContinuation.resume(throwing: error ?? HTTPAdapterError.nonHTTPResponse)
        }
        if let error {
            streamContinuation?.finish(throwing: error)
            session?.invalidateAndCancel()
        } else {
            streamContinuation?.finish()
            session?.finishTasksAndInvalidate()
        }
    }
}

public final class URLSessionHTTPTransport: HTTPTransport, HTTPStreamingTransport, @unchecked Sendable {
    public static let defaultMaximumResponseBytes = 32 * 1_024 * 1_024
    public static let defaultMaximumBufferedStreamChunks = 8
    public static let defaultMaximumStreamChunkBytes = 64 * 1_024

    private let maximumResponseBytes: Int
    private let maximumBufferedStreamChunks: Int
    private let maximumStreamChunkBytes: Int
    private let configuration: URLSessionConfiguration

    /// Production requests use a fresh ephemeral session, no persistent cache/cookies, no
    /// redirects, and a hard cumulative response limit. A custom configuration is for tests.
    public init(
        maximumResponseBytes: Int = URLSessionHTTPTransport.defaultMaximumResponseBytes,
        maximumBufferedStreamChunks: Int = URLSessionHTTPTransport.defaultMaximumBufferedStreamChunks,
        maximumStreamChunkBytes: Int = URLSessionHTTPTransport.defaultMaximumStreamChunkBytes,
        configuration: URLSessionConfiguration? = nil
    ) {
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
        self.maximumBufferedStreamChunks = min(64, max(1, maximumBufferedStreamChunks))
        self.maximumStreamChunkBytes = min(
            self.maximumResponseBytes,
            max(1_024, maximumStreamChunkBytes)
        )
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

    public func stream(
        for request: URLRequest
    ) async throws -> (AsyncThrowingStream<Data, Error>, HTTPURLResponse) {
        let cancellation = HTTPRequestCancellationBox()
        let pair = AsyncThrowingStream<Data, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(maximumBufferedStreamChunks)
        )
        let streamContinuation = pair.continuation

        let result = try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let delegate = CappedStreamingRequestDelegate(
                    maximumBytes: maximumResponseBytes,
                    maximumChunkBytes: maximumStreamChunkBytes,
                    stream: pair.stream,
                    streamContinuation: streamContinuation,
                    startContinuation: continuation
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
        do {
            try Task.checkCancellation()
        } catch {
            cancellation.cancel()
            streamContinuation.finish(throwing: CancellationError())
            throw CancellationError()
        }
        // Install consumer-lifetime cancellation only after the response continuation has safely
        // returned. Otherwise an immediately abandoned stream can cancel its URLSession task from
        // inside the response delegate before that delegate admits the response.
        streamContinuation.onTermination = { @Sendable _ in
            cancellation.cancel()
        }
        return result
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
    case streamBufferOverflow

    public var errorDescription: String? {
        switch self {
        case let .invalidURL(value): return "Invalid endpoint URL: \(value)"
        case .nonHTTPResponse: return "The endpoint did not return an HTTP response."
        case let .httpStatus(status, message): return "Endpoint returned HTTP \(status): \(message)"
        case let .invalidResponse(message): return "The endpoint response was invalid: \(message)"
        case let .missingModel(endpoint): return "Endpoint '\(endpoint)' requires a model name."
        case let .responseTooLarge(limit): return "Endpoint response exceeded the \(limit)-byte safety limit."
        case .streamBufferOverflow: return "The streaming response exceeded its bounded playback buffer."
        }
    }
}
