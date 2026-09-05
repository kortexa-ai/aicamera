import CryptoKit
import Foundation

public struct ModelArtifact: Sendable {
    public let url: URL
    public let sha256: String
    public let maximumBytes: Int64
    public let expectedBytes: Int64?

    public init(url: URL, sha256: String, maximumBytes: Int64, expectedBytes: Int64? = nil) {
        self.url = url; self.sha256 = sha256; self.maximumBytes = maximumBytes; self.expectedBytes = expectedBytes
    }
}

public struct ModelDownloadProgress: Sendable {
    public let receivedBytes: Int64
    public let expectedBytes: Int64?
    public var fraction: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }
}

/// Streams a public model artifact to a private temporary file, hashing each received chunk.
/// The caller owns the returned file. Failed/cancelled transfers remove their partial file.
public enum VerifiedModelDownload {
    public enum Failure: LocalizedError, Equatable {
        case invalidArtifact, invalidResponse, invalidSize, integrityMismatch, insecureRedirect
        public var errorDescription: String? {
            switch self {
            case .invalidArtifact: "The model download is not configured correctly."
            case .invalidResponse: "The model server returned an invalid response."
            case .invalidSize: "The model download has an unexpected size."
            case .integrityMismatch: "The downloaded model failed its integrity check. Please try again."
            case .insecureRedirect: "The model server redirected to an insecure address."
            }
        }
    }

    public static func download(
        _ artifact: ModelArtifact,
        configuration: URLSessionConfiguration = .ephemeral,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }
    ) async throws -> URL {
        try await Transfer(artifact: artifact, configuration: configuration, progress: progress).run()
    }
}

private final class Transfer: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let artifact: ModelArtifact
    private let configuration: URLSessionConfiguration
    private let progress: @Sendable (ModelDownloadProgress) -> Void
    private let queue = DispatchQueue(label: "ai.kortexa.aicamera.model-download", qos: .utility)
    // All mutable state, including delegate callbacks, belongs to queue.
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var file: FileHandle?
    private var temporaryURL: URL?
    private var bytes: Int64 = 0
    private var expectedBytes: Int64?
    private var hasher = SHA256()
    private var finished = false
    private var lastProgressTime: TimeInterval = 0

    init(artifact: ModelArtifact, configuration: URLSessionConfiguration,
         progress: @escaping @Sendable (ModelDownloadProgress) -> Void) {
        self.artifact = artifact; self.configuration = configuration; self.progress = progress
    }

    func run() async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { result in
                queue.async {
                    guard !self.finished else { result.resume(throwing: CancellationError()); return }
                    self.continuation = result
                    do { try self.start() }
                    catch { self.finish(.failure(error)) }
                }
            }
        } onCancel: {
            self.queue.async { self.finish(.failure(CancellationError())) }
        }
    }

    private func start() throws {
        guard artifact.url.scheme == "https", artifact.url.user == nil, artifact.url.password == nil,
              artifact.maximumBytes > 0, artifact.maximumBytes <= 4 * 1_024 * 1_024 * 1_024,
              artifact.sha256.utf8.count == 64,
              artifact.sha256.allSatisfy({ $0.isHexDigit }),
              artifact.expectedBytes.map({ $0 > 0 && $0 <= artifact.maximumBytes }) ?? true else {
            throw VerifiedModelDownload.Failure.invalidArtifact
        }
        let name = artifact.url.lastPathComponent
        let suffix = name.isEmpty || name == "." || name == ".." ? "model.bin" : name
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID())-\(suffix)")
        guard FileManager.default.createFile(atPath: temporary.path, contents: nil,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        temporaryURL = temporary
        file = try FileHandle(forWritingTo: temporary)
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        var request = URLRequest(url: artifact.url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        session.dataTask(with: request).resume()
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard !finished else { completionHandler(.cancel); return }
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            completionHandler(.cancel); finish(.failure(VerifiedModelDownload.Failure.invalidResponse)); return
        }
        guard response.expectedContentLength <= artifact.maximumBytes else {
            completionHandler(.cancel); finish(.failure(VerifiedModelDownload.Failure.invalidSize)); return
        }
        expectedBytes = artifact.expectedBytes ?? (response.expectedContentLength > 0 ? response.expectedContentLength : nil)
        reportProgress(force: true)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !finished else { return }
        guard Int64(data.count) <= artifact.maximumBytes - bytes else {
            finish(.failure(VerifiedModelDownload.Failure.invalidSize)); return
        }
        do {
            try file?.write(contentsOf: data)
            hasher.update(data: data)
            bytes += Int64(data.count)
            reportProgress(force: false)
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard !finished else { return }
        if let error { finish(.failure(error)); return }
        do {
            guard bytes > 0, artifact.expectedBytes.map({ $0 == bytes }) ?? true else {
                throw VerifiedModelDownload.Failure.invalidSize
            }
            try file?.close()
            file = nil
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == artifact.sha256.lowercased() else { throw VerifiedModelDownload.Failure.integrityMismatch }
            guard let temporaryURL else { throw CocoaError(.fileReadNoSuchFile) }
            reportProgress(force: true)
            finish(.success(temporaryURL))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard !finished, let url = request.url, url.scheme == "https", url.user == nil, url.password == nil else {
            completionHandler(nil); finish(.failure(VerifiedModelDownload.Failure.insecureRedirect)); return
        }
        completionHandler(request)
    }

    private func reportProgress(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastProgressTime >= 0.1 else { return }
        lastProgressTime = now
        progress(.init(receivedBytes: bytes, expectedBytes: expectedBytes))
    }

    private func finish(_ result: Result<URL, Error>) {
        guard !finished else { return }
        finished = true
        try? file?.close()
        file = nil
        session?.invalidateAndCancel()
        session = nil
        if case .failure = result, let temporaryURL { try? FileManager.default.removeItem(at: temporaryURL) }
        let completion = continuation
        continuation = nil
        completion?.resume(with: result)
    }
}
